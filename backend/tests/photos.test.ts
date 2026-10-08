// Integration tests for photos in chat: the search the assistant hands to the phone (with the
// user's own saved places for "the photo from where I went today"), the photos the phone reports it
// showed, real multimodal analysis of the ONE photo being talked about, sharing with confirmation,
// and cross-user protection. Runs the real app against the configured PostgreSQL database with mock
// Gemini models. Every place, time and image here is generated: nothing depends on fixed values.
// Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, afterEach, before, beforeEach, describe, test } from "node:test";
import type { LanguageModelV4CallOptions, LanguageModelV4GenerateResult } from "@ai-sdk/provider";
import { MockLanguageModelV4 } from "ai/test";
import { LocationSource, PermissionStatus, PermissionType } from "../generated/prisma/client";
import { createApp } from "../src/app";
import { prisma } from "../src/lib/prisma";
import { describeCapabilities } from "../src/modules/chat/ai/identity";
import { setChatModels } from "../src/modules/chat/ai/models";
import { detectImageType } from "../src/modules/chat/photos/photo-answer";
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
  { token, body }: { token?: string; body?: unknown } = {},
): Promise<{ status: number; json: any; raw: string }> {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
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
  const user = await registerVerifiedUser(call, name, `photos-${randomUUID()}@test.local`);
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

const word = () => randomUUID().replace(/[^a-z]/g, "").slice(0, 8) || "place";
const cap = (w: string) => w[0].toUpperCase() + w.slice(1);

/** A real (tiny) PNG with random pixels, so every test image is different. */
function randomPng(): Buffer {
  const header = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  return Buffer.concat([header, randomBytes(200)]);
}

/** A saved location for [user] at [capturedAt], with a generated place name. */
async function seedVisit(user: TestUser, capturedAt: Date, placeName = `${cap(word())} ${cap(word())}`) {
  const latitude = 10 + Math.random() * 20;
  const longitude = 70 + Math.random() * 20;
  await prisma.locationHistory.create({
    data: { userId: user.id, source: LocationSource.AUTOMATIC, latitude, longitude, placeName, capturedAt },
  });
  return { placeName, latitude, longitude };
}

// ---------------------------------------------------------------------------------------------
// Mock Gemini. The chat turn calls one tool and then replies; the vision call is told apart by its
// instructions and records exactly what it received.

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

interface VisionCall {
  instructions: string;
  text: string;
  files: Array<{ mediaType: string; bytes: Buffer }>;
}

function toBytes(data: unknown): Buffer {
  if (data instanceof Uint8Array) return Buffer.from(data);
  if (typeof data === "string") return Buffer.from(data, "base64");
  if (data && typeof data === "object" && "data" in data) return toBytes((data as { data: unknown }).data);
  return Buffer.alloc(0);
}

/**
 * A model whose chat turn calls [toolName] with [input] and then replies with the tool result, and
 * whose vision calls answer [visionAnswer] (or throw, when [visionFails]).
 */
function scripted(toolName: string, input: unknown, opts: { visionAnswer?: string; visionFails?: boolean } = {}) {
  const vision: VisionCall[] = [];
  const turns: string[] = [];
  const model = new MockLanguageModelV4({
    doGenerate: async (options: LanguageModelV4CallOptions) => {
      const system = options.prompt.filter((p) => p.role === "system").map((p) => p.content as string).join("\n");
      if (system.includes("chose ONE photo")) {
        const user = options.prompt.find((p) => p.role === "user");
        const parts = Array.isArray(user?.content) ? user.content : [];
        vision.push({
          instructions: system,
          text: parts.filter((c: any) => c.type === "text").map((c: any) => c.text).join(""),
          files: parts.filter((c: any) => c.type === "file").map((c: any) => ({ mediaType: c.mediaType, bytes: toBytes(c.data) })),
        });
        if (opts.visionFails) throw new Error(`provider exploded: ${JSON.stringify(parts).slice(0, 4000)}`);
        return text(opts.visionAnswer ?? "The photo shows a red car parked near some trees.");
      }
      if (system.includes("word title")) return text("Photos");
      turns.push(JSON.stringify(options.prompt));
      const last = options.prompt[options.prompt.length - 1];
      if (last?.role === "tool") {
        const result = last.content.find((c: any) => c.type === "tool-result") as any;
        return text(`RESULT ${JSON.stringify(result?.output?.value ?? result?.output ?? null)}`);
      }
      return toolCall(toolName, input);
    },
  });
  return { model, vision, turns };
}

async function chat(user: TestUser, message: string, conversationId?: string) {
  return call("POST", "/api/chat", { token: user.token, body: { message, ...(conversationId ? { conversationId } : {}) } });
}

/** One chat turn in which the model calls [toolName]; returns the turn and its photo event. */
async function turn(
  user: TestUser,
  toolName: string,
  input: unknown,
  conversationId?: string,
  opts: { visionAnswer?: string; visionFails?: boolean } = {},
) {
  const script = scripted(toolName, input, opts);
  setChatModels({ chat: script.model });
  const res = await chat(user, `please ${word()}`, conversationId);
  assert.equal(res.status, 200, res.raw);
  return { res, raw: res.raw, ...script, event: res.json.toolEvents[0], conversationId: res.json.conversationId as string };
}

const resultsPath = (id: string) => `/api/chat/photo-searches/${id}/results`;
const answerPath = (id: string) => `/api/chat/photo-analyses/${id}/answer`;
const failPath = (id: string) => `/api/chat/photo-analyses/${id}/fail`;

/** Generated photos the phone "showed", taken over the last hours. */
function shown(count: number, place?: { name: string; evidence: "gps" | "time" }) {
  return Array.from({ length: count }, (_, i) => ({
    capturedAt: new Date(Date.now() - (i + 1) * 3_600_000 * Math.random()).toISOString(),
    width: 1000 + Math.floor(Math.random() * 3000),
    height: 1000 + Math.floor(Math.random() * 3000),
    ...(place ? { place } : {}),
  }));
}

/** Searches and reports [count] shown photos; returns the conversation and minted photos. */
async function findPhotos(user: TestUser, count: number, conversationId?: string, place?: { name: string; evidence: "gps" | "time" }) {
  const t = await turn(user, "get_photo_candidates", { period: "today" }, conversationId);
  const report = await call("POST", resultsPath(t.event.data.requestId), {
    token: user.token,
    body: { conversationId: t.conversationId, outcome: "found", photos: shown(count, place), total: count },
  });
  assert.equal(report.status, 200, report.raw);
  return { conversationId: t.conversationId, photos: report.json.photos as any[], report };
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
    await setPermission(user, PermissionType.PHOTOS, PermissionStatus.GRANTED);
    await setPermission(user, PermissionType.LOCATION, PermissionStatus.GRANTED);
    await setPermission(user, PermissionType.CONTACTS, PermissionStatus.GRANTED);
  }
});

afterEach(() => setChatModels(null));

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

// ---------------------------------------------------------------------------------------------

describe("photo search: handed to the phone", () => {
  test("date-based search opens a request; the model is told it cannot see the photos", async () => {
    const t = await turn(userA, "get_photo_candidates", { period: "yesterday" });
    assert.equal(t.event.kind, "photos");
    assert.equal(t.event.status, "device_lookup");
    const { query, visits, requestId } = t.event.data;
    assert.equal(query.locationContext, false);
    assert.ok(query.startDate && query.endDate, "a date range for the phone");
    assert.equal(new Date(query.endDate).getTime() - new Date(query.startDate).getTime(), 86_400_000);
    assert.deepEqual(visits, []);
    const row = await prisma.photoRequest.findUniqueOrThrow({ where: { id: requestId } });
    assert.equal(row.userId, userA.id);
    assert.equal(row.kind, "SEARCH");
    assert.match(t.res.json.response, /You cannot see the photos/);
  });

  test("location context: the phone gets today's saved places of THIS user only", async () => {
    const mine = await seedVisit(userA, new Date(Date.now() - 30 * 60_000));
    const theirs = await seedVisit(userB, new Date(Date.now() - 20 * 60_000));
    const t = await turn(userA, "get_photo_candidates", { period: "today", locationContext: true });
    const names = t.event.data.visits.map((v: any) => v.placeName);
    assert.ok(names.includes(mine.placeName), "own place included");
    assert.ok(!names.includes(theirs.placeName), "another user's place is never sent");
    assert.equal(t.event.data.query.locationContext, true);
  });

  test("a named place narrows the saved places to that one", async () => {
    const park = await seedVisit(userA, new Date(Date.now() - 2 * 86_400_000), `${cap(word())} Park`);
    await seedVisit(userA, new Date(Date.now() - 3 * 86_400_000), `${cap(word())} School`);
    const t = await turn(userA, "get_photo_candidates", { place: park.placeName.split(" ")[0] });
    assert.deepEqual(t.event.data.visits.map((v: any) => v.placeName), [park.placeName]);
  });

  test("location context needs Location permission; photos need Photos permission", async () => {
    await setPermission(userA, PermissionType.LOCATION, PermissionStatus.DENIED);
    let t = await turn(userA, "get_photo_candidates", { locationContext: true });
    assert.deepEqual(t.event, { kind: "photos", status: "permission_required", permission: "LOCATION" });

    await setPermission(userA, PermissionType.PHOTOS, PermissionStatus.DENIED);
    t = await turn(userA, "get_photo_candidates", { period: "today" });
    assert.deepEqual(t.event, { kind: "photos", status: "permission_required", permission: "PHOTOS" });
  });

  test("limited Photos access still searches (the OS limits what the phone sees)", async () => {
    await setPermission(userA, PermissionType.PHOTOS, PermissionStatus.LIMITED);
    const t = await turn(userA, "get_photo_candidates", { latest: true });
    assert.equal(t.event.status, "device_lookup");
    assert.equal(t.event.data.query.latest, true);
  });

  test("the model cannot choose whose photos are searched", async () => {
    const t = await turn(userA, "get_photo_candidates", { period: "today", userId: userB.id });
    // The strict schema rejects the argument before the tool runs: nothing is searched for anyone.
    assert.ok(!t.res.json.toolEvents.some((e: any) => e.status === "device_lookup"), t.raw);
    assert.equal(await prisma.photoRequest.count({ where: { conversationId: t.conversationId } }), 0);
  });
});

describe("photo search: results reported by the phone", () => {
  test("one strong match: an opaque id is minted, selected, and the history says so", async () => {
    const place = { name: `${cap(word())} Market`, evidence: "gps" as const };
    const { photos, report, conversationId } = await findPhotos(userA, 1, undefined, place);
    assert.equal(photos.length, 1);
    assert.match(photos[0].id, /^photo_[a-f0-9]{20}$/);
    assert.equal(photos[0].selected, true);
    assert.equal(photos[0].placeName, place.name);
    assert.equal(report.json.message.content, `I found a matching photo, taken near ${place.name}.`);

    const row = await prisma.photoReference.findUniqueOrThrow({ where: { id: photos[0].id } });
    assert.equal(row.userId, userA.id);
    assert.equal(row.conversationId, conversationId);
  });

  test("a match by time only is never claimed to be taken at the place", async () => {
    const place = { name: `${cap(word())} Library`, evidence: "time" as const };
    const { report } = await findPhotos(userA, 1, undefined, place);
    assert.equal(report.json.message.content, `I found a matching photo, taken around the time you were at ${place.name}.`);
    assert.doesNotMatch(report.json.message.content, /taken near|taken at/);
  });

  test("several strong matches: the user is asked which one, nothing is selected", async () => {
    const { photos, report } = await findPhotos(userA, 3);
    assert.equal(photos.length, 3);
    assert.ok(photos.every((p) => p.selected === false));
    assert.equal(report.json.message.content, "I found 3 matching photos. Which one would you like?");
  });

  test("no match: a clear message, no photo ids", async () => {
    const t = await turn(userA, "get_photo_candidates", { locationContext: true, period: "today" });
    const res = await call("POST", resultsPath(t.event.data.requestId), {
      token: userA.token,
      body: { outcome: "none", reason: "no_visits", limited: true },
    });
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json.photos, []);
    assert.match(res.json.message.content, /^I couldn't find a matching photo in your available photos\./);
    assert.match(res.json.message.content, /no saved locations/);
    assert.match(res.json.message.content, /only see the photos you allowed/);
  });

  test("permission denied on the phone is said plainly", async () => {
    const t = await turn(userA, "get_photo_candidates", { period: "today" });
    const res = await call("POST", resultsPath(t.event.data.requestId), { token: userA.token, body: { outcome: "permission_denied" } });
    assert.match(res.json.message.content, /Photos permission is turned off/);
  });

  test("paths, URIs, file contents and unknown fields are rejected outright", async () => {
    const t = await turn(userA, "get_photo_candidates", { period: "today" });
    const id = t.event.data.requestId;
    for (const photo of [
      { ...shown(1)[0], uri: "content://media/external/images/media/42" },
      { ...shown(1)[0], path: "/storage/emulated/0/DCIM/Camera/IMG_1.jpg" },
      { ...shown(1)[0], place: { name: "<b>x</b>", evidence: "gps" } },
    ]) {
      const res = await call("POST", resultsPath(id), { token: userA.token, body: { outcome: "found", photos: [photo] } });
      assert.equal(res.status, 400, res.raw);
    }
    const res = await call("POST", resultsPath(id), { token: userA.token, body: { outcome: "found", photos: shown(1), userId: userB.id } });
    assert.equal(res.status, 400);
    assert.equal(await prisma.photoReference.count({ where: { conversationId: t.conversationId } }), 0);
  });

  test("a request is answered once; another user cannot answer it", async () => {
    const t = await turn(userA, "get_photo_candidates", { period: "today" });
    const id = t.event.data.requestId;
    const other = await call("POST", resultsPath(id), { token: userB.token, body: { outcome: "found", photos: shown(1) } });
    assert.equal(other.status, 404);
    assert.equal((await call("POST", resultsPath(id), { token: userA.token, body: { outcome: "none" } })).status, 200);
    assert.equal((await call("POST", resultsPath(id), { token: userA.token, body: { outcome: "none" } })).status, 409);
  });

  test("selecting a photo: own photos only", async () => {
    const { photos, conversationId } = await findPhotos(userA, 2);
    assert.equal((await call("POST", `/api/chat/photos/${photos[1].id}/select`, { token: userB.token, body: {} })).status, 404);
    const res = await call("POST", `/api/chat/photos/${photos[1].id}/select`, { token: userA.token, body: { conversationId } });
    assert.equal(res.status, 200, res.raw);
    assert.equal(res.json.photo.selected, true);
    assert.equal((await call("POST", `/api/chat/photos/not-a-photo/select`, { token: userA.token, body: {} })).status, 400);
  });
});

describe("photo analysis: real multimodal input", () => {
  test("'What is in this photo?' sends the actual image to Gemini vision and saves its answer", async () => {
    const { photos, conversationId } = await findPhotos(userA, 1);
    const question = `What is in this photo ${word()}?`;
    const answer = `This photo shows a ${word()} next to a blue bicycle.`;
    const t = await turn(userA, "analyze_photo", { question }, conversationId, { visionAnswer: answer });
    assert.deepEqual(t.event, { kind: "photo_analysis", status: "device_lookup", data: { requestId: t.event.data.requestId, photoId: photos[0].id } });
    assert.match(t.res.json.response, /never describe or guess/);

    const image = randomPng();
    const res = await call("POST", answerPath(t.event.data.requestId), {
      token: userA.token,
      body: { conversationId, photoId: photos[0].id, image: image.toString("base64") },
    });
    assert.equal(res.status, 200, res.raw);
    assert.equal(res.json.message.content, answer);

    // Gemini received the real image bytes (not a file name) with the question.
    assert.equal(t.vision.length, 1);
    assert.equal(t.vision[0].files.length, 1);
    assert.equal(t.vision[0].files[0].mediaType, "image/png");
    assert.ok(t.vision[0].files[0].bytes.equals(image), "the exact image bytes reached the model");
    assert.match(t.vision[0].text, new RegExp(question.replace(/[?]/g, "\\?")));
    assert.match(t.vision[0].instructions, /Answer only from what is actually visible/);

    // Nothing of the image is stored; the question is cleared.
    const row = await prisma.photoRequest.findUniqueOrThrow({ where: { id: t.event.data.requestId } });
    assert.equal(row.status, "COMPLETED");
    assert.equal(row.question, null);
    const stored = await prisma.chatMessage.findMany({ where: { conversationId } });
    assert.ok(stored.every((m) => !m.content.includes(image.toString("base64").slice(0, 40))));
  });

  test("follow-up questions use the same photo without searching again", async () => {
    const { photos, conversationId } = await findPhotos(userA, 1);
    for (const question of ["What is in it?", "Is there a car in it?"]) {
      const t = await turn(userA, "analyze_photo", { question }, conversationId);
      assert.equal(t.event.data.photoId, photos[0].id);
      assert.ok(!t.res.json.toolEvents.some((e: any) => e.kind === "photos"), "no new search");
      const res = await call("POST", answerPath(t.event.data.requestId), {
        token: userA.token,
        body: { photoId: photos[0].id, image: randomPng().toString("base64") },
      });
      assert.equal(res.status, 200, res.raw);
    }
  });

  test("the picked photo of several is the one analysed; before picking, the model must ask", async () => {
    const { photos, conversationId } = await findPhotos(userA, 3);
    let t = await turn(userA, "analyze_photo", { question: "What is in it?" }, conversationId);
    assert.equal(t.event.status, "unavailable");
    assert.match(t.res.json.response, /NO_PHOTO_SELECTED/);
    assert.match(t.res.json.response, /Several photos were shown/);

    await call("POST", `/api/chat/photos/${photos[2].id}/select`, { token: userA.token, body: { conversationId } });
    t = await turn(userA, "analyze_photo", { question: "What is in it?" }, conversationId);
    assert.equal(t.event.data.photoId, photos[2].id);
  });

  test("no photo in the chat: nothing is invented", async () => {
    const t = await turn(userA, "analyze_photo", { question: "What is in this picture?" });
    assert.match(t.res.json.response, /NO_PHOTO_SELECTED/);
    assert.equal(t.vision.length, 0, "the vision model is never called without an image");
  });

  test("another user's photo id is not found (cross-user protection)", async () => {
    const { photos } = await findPhotos(userA, 1);
    const t = await turn(userB, "analyze_photo", { photoId: photos[0].id, question: "What is in it?" });
    assert.match(t.res.json.response, /PHOTO_NOT_FOUND/);
    assert.equal(await prisma.photoRequest.count({ where: { userId: userB.id, photoId: photos[0].id } }), 0);

    const view = await turn(userB, "get_photo", { photoId: photos[0].id });
    assert.match(view.res.json.response, /PHOTO_NOT_FOUND/);
  });

  test("the phone must send the photo the request is about, as a real image", async () => {
    const { photos, conversationId } = await findPhotos(userA, 2);
    await call("POST", `/api/chat/photos/${photos[0].id}/select`, { token: userA.token, body: { conversationId } });
    const t = await turn(userA, "analyze_photo", { question: "What is in it?" }, conversationId);
    const id = t.event.data.requestId;

    // A different photo, or another user answering: refused before anything is read.
    let res = await call("POST", answerPath(id), { token: userA.token, body: { photoId: photos[1].id, image: randomPng().toString("base64") } });
    assert.equal(res.status, 404);
    res = await call("POST", answerPath(id), { token: userB.token, body: { photoId: photos[0].id, image: randomPng().toString("base64") } });
    assert.equal(res.status, 404);

    // Not an image: unsupported, said plainly.
    res = await call("POST", answerPath(id), {
      token: userA.token,
      body: { photoId: photos[0].id, image: Buffer.from(`not an image ${word()}`.repeat(10)).toString("base64") },
    });
    assert.equal(res.status, 415);
    assert.equal(res.json.code, "UNSUPPORTED_IMAGE");
    assert.equal(t.vision.length, 0);
  });

  test("Gemini vision failure: an honest error, and the image never reaches the log", async () => {
    const { photos, conversationId } = await findPhotos(userA, 1);
    const t = await turn(userA, "analyze_photo", { question: "Describe this image" }, conversationId, { visionFails: true });
    const image = randomPng().toString("base64");
    const logged: string[] = [];
    const original = console.error;
    console.error = (...args: unknown[]) => logged.push(args.map(String).join(" "));
    let res;
    try {
      res = await call("POST", answerPath(t.event.data.requestId), { token: userA.token, body: { photoId: photos[0].id, image } });
    } finally {
      console.error = original;
    }
    assert.equal(res.status, 503);
    assert.equal(res.json.code, "AI_UNAVAILABLE");
    assert.ok(logged.length > 0);
    assert.ok(logged.every((l) => !l.includes(image.slice(0, 40)) && !l.includes("provider exploded")), "only the error name is logged");
    const last = await prisma.chatMessage.findFirst({ where: { conversationId }, orderBy: { createdAt: "desc" } });
    assert.match(last!.content, /couldn't look at the photo/);
  });

  test("a deleted or unavailable photo is reported by the phone, never guessed", async () => {
    const { conversationId } = await findPhotos(userA, 1);
    const t = await turn(userA, "analyze_photo", { question: "What is in it?" }, conversationId);
    const res = await call("POST", failPath(t.event.data.requestId), { token: userA.token, body: { reason: "unavailable" } });
    assert.equal(res.status, 200, res.raw);
    assert.equal(res.json.message.content, "This photo is no longer available on your device.");
    assert.equal(t.vision.length, 0);
  });

  test("image type detection only accepts real JPEG, PNG and WebP data", () => {
    assert.equal(detectImageType(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2])), "image/jpeg");
    assert.equal(detectImageType(randomPng()), "image/png");
    assert.equal(detectImageType(Buffer.concat([Buffer.from("RIFF"), randomBytes(4), Buffer.from("WEBP")])), "image/webp");
    assert.equal(detectImageType(Buffer.from(`/storage/emulated/0/DCIM/${word()}.jpg`)), null);
  });
});

describe("photo sharing: always confirmed, never claimed as sent", () => {
  test("'Share this photo on WhatsApp' asks the user to confirm on the phone", async () => {
    const { photos, conversationId } = await findPhotos(userA, 1);
    const t = await turn(userA, "share_photo", { app: "whatsapp" }, conversationId);
    assert.equal(t.event.kind, "photo_share");
    assert.equal(t.event.status, "confirmation_required");
    assert.equal(t.event.data.photo.id, photos[0].id);
    assert.equal(t.event.data.app, "whatsapp");
    assert.doesNotMatch(t.res.json.response, /"success":true[^]*sent successfully/);
  });

  test("sending the photo to a named contact goes through the confirmation flow", async () => {
    const { photos, conversationId } = await findPhotos(userA, 1);
    const name = cap(word());
    const t = await turn(userA, "prepare_whatsapp", { recipientName: name, sharePhoto: true }, conversationId);
    assert.equal(t.res.json.pendingActions.length, 1, t.res.raw);
    const action = t.res.json.pendingActions[0];
    assert.equal(action.type, "SHARE_PHOTO");
    assert.equal(action.photoId, photos[0].id);
    assert.equal(action.summary, `Do you want to share this photo with ${name} on WhatsApp?`);
    assert.match(action.dataSummary, /^Photo taken \d{4}-\d{2}-\d{2} at /);

    const phone = `98${String(Math.floor(Math.random() * 1e8)).padStart(8, "0")}`;
    await call("POST", `/api/chat/actions/${action.id}/recipient`, { token: userA.token, body: { address: phone, name } });
    // Another user cannot confirm it.
    assert.equal((await call("POST", `/api/chat/actions/${action.id}/confirm`, { token: userB.token, body: {} })).status, 404);
    const confirmed = await call("POST", `/api/chat/actions/${action.id}/confirm`, { token: userA.token, body: {} });
    assert.equal(confirmed.status, 200, confirmed.raw);
    assert.equal(confirmed.json.action.status, "CONFIRMED");
    assert.equal(confirmed.json.action.handoff.photoId, photos[0].id);
    assert.doesNotMatch(confirmed.raw, /content:\/\/|\/storage\//);

    const done = await call("POST", `/api/chat/actions/${action.id}/handoff`, { token: userA.token, body: { result: "whatsapp_opened" } });
    assert.equal(done.json.action.outcomeMessage, "WhatsApp opened. Tap Send to complete it.");
    assert.doesNotMatch(done.json.action.outcomeMessage, /\bsent\b/i);
  });

  test("without a photo in the chat, nothing is prepared; photos cannot be emailed", async () => {
    let t = await turn(userA, "prepare_whatsapp", { recipientName: cap(word()), sharePhoto: true });
    assert.deepEqual(t.res.json.pendingActions, []);
    assert.match(t.res.json.response, /NO_PHOTO_SELECTED/);

    const { conversationId } = await findPhotos(userA, 1);
    t = await turn(userA, "prepare_email", { recipientName: cap(word()), sharePhoto: true }, conversationId);
    assert.deepEqual(t.res.json.pendingActions, []);
    assert.match(t.res.json.response, /NOT_SUPPORTED/);
  });
});

describe("assistant knowledge", () => {
  test("capabilities and rules describe photo search and analysis honestly", async () => {
    const can = describeCapabilities().join("\n");
    assert.match(can, /find photos on this phone/);
    assert.match(can, /look at one photo you choose/);
    const t = await turn(userA, "get_profile", {});
    assert.match(t.turns[0], /PHOTO RULES/);
    assert.match(t.turns[0], /must not|never claim to see a photo/i);
  });
});
