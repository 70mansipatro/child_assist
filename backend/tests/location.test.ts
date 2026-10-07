// Integration tests for the Phase 4 location API.
// Runs the real app against the configured PostgreSQL database (DATABASE_URL) and removes
// the users it creates afterwards. Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import { createApp } from "../src/app";
import { registerVerifiedUser } from "./support/auth";
import { prisma } from "../src/lib/prisma";

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
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const raw = await res.text();
  return { status: res.status, json: raw ? JSON.parse(raw) : null, raw };
}

async function registerUser(name: string): Promise<TestUser> {
  const user = await registerVerifiedUser(call, name, `phase4-${randomUUID()}@test.local`);
  createdUserIds.push(user.id);
  return { id: user.id, token: user.token };
}

function minutesAgo(minutes: number): string {
  return new Date(Date.now() - minutes * 60_000).toISOString();
}

async function save(user: TestUser, body: Record<string, unknown>) {
  return call("POST", "/api/location", { token: user.token, body });
}

async function history(user: TestUser, query = "") {
  const res = await call("GET", `/api/location/history${query}`, { token: user.token });
  assert.equal(res.status, 200, res.raw);
  return res.json.locations as Array<{ id: string; latitude: number; longitude: number; accuracy: number | null; capturedAt: string }>;
}

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  userA = await registerUser("Location A");
  userB = await registerUser("Location B");
});

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("location", () => {
  let aLocationId: string;
  let bLocationId: string;

  test("1. User A saves a location", async () => {
    const capturedAt = minutesAgo(10);
    const res = await save(userA, { latitude: 20.2961, longitude: 85.8245, accuracy: 12.5, capturedAt });
    assert.equal(res.status, 201, res.raw);
    assert.deepEqual(Object.keys(res.json.location).sort(), [
      "accuracy", "address", "capturedAt", "city", "country", "id", "latitude", "locality",
      "longitude", "placeName", "postalCode", "state", "street",
    ]);
    assert.equal(res.json.location.latitude, 20.2961);
    assert.equal(res.json.location.longitude, 85.8245);
    assert.equal(res.json.location.accuracy, 12.5);
    assert.equal(res.json.location.capturedAt, capturedAt);
    assert.ok(!res.raw.includes(userA.id), "response must not expose the owner id");
    aLocationId = res.json.location.id;

    // Identical coordinates at another time are a separate, valid record; accuracy is optional.
    const again = await save(userA, { latitude: 20.2961, longitude: 85.8245, capturedAt: minutesAgo(5) });
    assert.equal(again.status, 201, again.raw);
    assert.equal(again.json.location.accuracy, null);
    assert.equal(again.json.location.placeName, null);
  });

  test("2. User B saves a location", async () => {
    const res = await save(userB, { latitude: -33.8688, longitude: 151.2093, accuracy: 30, capturedAt: minutesAgo(1) });
    assert.equal(res.status, 201, res.raw);
    bLocationId = res.json.location.id;
  });

  test("3. User A's history contains only User A's locations, newest first", async () => {
    const locations = await history(userA);
    assert.equal(locations.length, 2);
    assert.ok(locations.every((l) => l.latitude === 20.2961));
    assert.ok(!locations.some((l) => l.id === bLocationId));
    assert.ok(new Date(locations[0].capturedAt) > new Date(locations[1].capturedAt));
    assert.equal(locations[1].id, aLocationId);

    assert.equal((await history(userA, "?limit=1")).length, 1);
    assert.equal((await history(userA, `?before=${encodeURIComponent(minutesAgo(7))}`)).length, 1);
    assert.equal((await history(userA, `?since=${encodeURIComponent(minutesAgo(7))}`)).length, 1);
  });

  test("4. User B's history contains only User B's location", async () => {
    const locations = await history(userB);
    assert.deepEqual(locations.map((l) => l.id), [bLocationId]);
  });

  test("5. User A cannot delete User B's location", async () => {
    const res = await call("DELETE", `/api/location/${bLocationId}`, { token: userA.token });
    assert.equal(res.status, 404, res.raw);
    assert.equal(await prisma.locationHistory.count({ where: { id: bLocationId } }), 1);

    // Nor reach B's data through a user ID in the query or body.
    assert.equal((await call("DELETE", `/api/location/history?userId=${userB.id}`, { token: userA.token })).status, 400);
    assert.equal((await call("GET", `/api/location/history?userId=${userB.id}`, { token: userA.token })).status, 400);
    const spoof = await save(userA, { latitude: 1, longitude: 1, capturedAt: minutesAgo(1), userId: userB.id });
    assert.equal(spoof.status, 400, spoof.raw);
    assert.deepEqual((await history(userB)).map((l) => l.id), [bLocationId]);
  });

  test("6. Unauthenticated requests return 401", async () => {
    const body = { latitude: 1, longitude: 1, capturedAt: minutesAgo(1) };
    assert.equal((await call("POST", "/api/location", { body })).status, 401);
    assert.equal((await call("GET", "/api/location/history")).status, 401);
    assert.equal((await call("DELETE", "/api/location/history")).status, 401);
    assert.equal((await call("DELETE", `/api/location/${aLocationId}`)).status, 401);
    assert.equal((await call("GET", "/api/location/history", { token: "not-a-jwt" })).status, 401);
  });

  test("7. Invalid latitude returns 400", async () => {
    for (const latitude of [90.0001, -91, "20.1", null, undefined]) {
      const res = await save(userA, { latitude, longitude: 1, capturedAt: minutesAgo(1) });
      assert.equal(res.status, 400, `latitude ${latitude}: ${res.raw}`);
      assert.match(res.json.errors[0].message, /latitude/i);
    }
  });

  test("8. Invalid longitude returns 400", async () => {
    for (const longitude of [180.5, -181, "85", null]) {
      const res = await save(userA, { latitude: 1, longitude, capturedAt: minutesAgo(1) });
      assert.equal(res.status, 400, `longitude ${longitude}: ${res.raw}`);
      assert.match(res.json.errors[0].message, /longitude/i);
    }
  });

  test("9. Invalid accuracy returns 400", async () => {
    for (const accuracy of [-1, "12"]) {
      const res = await save(userA, { latitude: 1, longitude: 1, accuracy, capturedAt: minutesAgo(1) });
      assert.equal(res.status, 400, `accuracy ${accuracy}: ${res.raw}`);
      assert.match(res.json.errors[0].message, /accuracy/i);
    }
  });

  test("Invalid capturedAt, limit and id return 400", async () => {
    const future = new Date(Date.now() + 60 * 60_000).toISOString();
    for (const capturedAt of ["yesterday", "2026-13-01T00:00:00Z", future, undefined]) {
      const res = await save(userA, { latitude: 1, longitude: 1, capturedAt });
      assert.equal(res.status, 400, `capturedAt ${capturedAt}: ${res.raw}`);
    }
    for (const limit of ["0", "101", "abc", "1.5"]) {
      const res = await call("GET", `/api/location/history?limit=${limit}`, { token: userA.token });
      assert.equal(res.status, 400, `limit ${limit}: ${res.raw}`);
    }
    assert.equal((await call("DELETE", "/api/location/not-a-uuid", { token: userA.token })).status, 400);
    assert.equal((await call("DELETE", `/api/location/${randomUUID()}`, { token: userA.token })).status, 404);
    assert.equal((await history(userA)).length, 2, "no invalid request created a record");
  });

  test("12. Place name and address are saved and returned", async () => {
    const place = {
      placeName: "Jayadev Vihar",
      address: "Jayadev Vihar, Bhubaneswar, Odisha, India",
      street: "Jayadev Vihar",
      locality: "Bhubaneswar",
      city: "Bhubaneswar",
      state: "Odisha",
      postalCode: "751013",
      country: "India",
    };
    const res = await save(userB, { latitude: 20.2961, longitude: 85.8245, accuracy: 12.5, ...place, capturedAt: minutesAgo(0.5) });
    assert.equal(res.status, 201, res.raw);
    const stored = await prisma.locationHistory.findUniqueOrThrow({ where: { id: res.json.location.id } });
    assert.equal(stored.userId, userB.id);
    for (const [key, value] of Object.entries(place)) {
      assert.equal(res.json.location[key], value, key);
      assert.equal(stored[key as keyof typeof place], value, key);
    }
    const listed = (await history(userB)).find((l) => l.id === res.json.location.id) as any;
    assert.equal(listed.placeName, "Jayadev Vihar");
    assert.equal(listed.address, place.address);
    await call("DELETE", `/api/location/${res.json.location.id}`, { token: userB.token });
  });

  test("13. Place fields are optional and nullable; blank becomes null", async () => {
    const res = await save(userB, {
      latitude: 1, longitude: 2, placeName: null, address: "   ", city: null, capturedAt: minutesAgo(0.5),
    });
    assert.equal(res.status, 201, res.raw);
    for (const key of ["placeName", "address", "street", "locality", "city", "state", "postalCode", "country"]) {
      assert.equal(res.json.location[key], null, key);
    }
    await call("DELETE", `/api/location/${res.json.location.id}`, { token: userB.token });

    for (const body of [
      { placeName: "x".repeat(256) },
      { address: "x".repeat(1001) },
      { country: 42 },
      { state: ["Odisha"] },
    ]) {
      const bad = await save(userB, { latitude: 1, longitude: 2, capturedAt: minutesAgo(1), ...body });
      assert.equal(bad.status, 400, `${JSON.stringify(body).slice(0, 60)}: ${bad.raw}`);
    }
    assert.deepEqual((await history(userB)).map((l) => l.id), [bLocationId]);
  });

  test("14. History is newest first by capture time, not insert order", async () => {
    const temp = await registerUser("Order");
    for (const [i, m] of [[1, 30], [2, 5], [3, 60], [4, 15]] as const) {
      await save(temp, { latitude: i, longitude: i, placeName: `P${i}`, capturedAt: minutesAgo(m) });
    }
    const names = (await history(temp)).map((l: any) => l.placeName);
    assert.deepEqual(names, ["P2", "P4", "P1", "P3"]);
  });

  test("User A can delete one of their own locations", async () => {
    const res = await call("DELETE", `/api/location/${aLocationId}`, { token: userA.token });
    assert.equal(res.status, 200, res.raw);
    assert.equal((await history(userA)).length, 1);
  });

  test("10. Deleting history only deletes the current user's records", async () => {
    await save(userA, { latitude: 10, longitude: 10, capturedAt: minutesAgo(2) });
    const res = await call("DELETE", "/api/location/history", { token: userA.token });
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json, { deleted: 2 });
    assert.equal((await history(userA)).length, 0);
    assert.deepEqual((await history(userB)).map((l) => l.id), [bLocationId]);

    const empty = await call("DELETE", "/api/location/history", { token: userA.token });
    assert.deepEqual(empty.json, { deleted: 0 });
  });

  test("11 + 12. Deleting User A cascades to A's history and leaves B's intact", async () => {
    await save(userA, { latitude: 5, longitude: 5, capturedAt: minutesAgo(1) });
    assert.equal(await prisma.locationHistory.count({ where: { userId: userA.id } }), 1);

    await prisma.user.delete({ where: { id: userA.id } });

    assert.equal(await prisma.locationHistory.count({ where: { userId: userA.id } }), 0);
    assert.deepEqual((await history(userB)).map((l) => l.id), [bLocationId]);
    // A token for the deleted account can no longer write.
    const res = await save(userA, { latitude: 1, longitude: 1, capturedAt: minutesAgo(1) });
    assert.equal(res.status, 401, res.raw);
  });
});
