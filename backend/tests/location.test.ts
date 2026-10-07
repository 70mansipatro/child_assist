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
import { PERIODS, expectedRange, localInstant, localToday, shiftDays } from "./support/dates";
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
      "longitude", "placeName", "postalCode", "source", "state", "street",
    ]);
    assert.equal(res.json.saved, true);
    // Without a source, a save is a manual one, as before automatic history existed.
    assert.equal(res.json.location.source, "MANUAL");
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
    // Too-large limits are clamped (see the date-search tests); nonsense ones are rejected.
    for (const limit of ["0", "-5", "abc", "1.5"]) {
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

describe("location history by date", () => {
  // India, as on the test phone. Every search below passes this offset, as the app does.
  const IST = 330;
  let traveller: TestUser;
  let other: TestUser;
  /** placeName -> local date it was captured on. */
  const savedOn = new Map<string, string>();

  async function search(user: TestUser, query: Record<string, string | number>) {
    const qs = new URLSearchParams(Object.entries(query).map(([k, v]) => [k, String(v)])).toString();
    return call("GET", `/api/location/history?${qs}`, { token: user.token });
  }

  async function names(user: TestUser, query: Record<string, string | number>) {
    const res = await search(user, query);
    assert.equal(res.status, 200, res.raw);
    return res.json.locations.map((l: { placeName: string }) => l.placeName) as string[];
  }

  before(async () => {
    traveller = await registerUser("Traveller");
    other = await registerUser("Other");
    const today = localToday(IST);
    const localMidnight = localInstant(today, 0, 0, IST).getTime();
    // Today's visit sits halfway between local midnight and now, so it is never in the future.
    await save(traveller, {
      latitude: 20.2961,
      longitude: 85.8245,
      placeName: "today",
      capturedAt: new Date((localMidnight + Date.now()) / 2).toISOString(),
    });
    savedOn.set("today", today);
    for (const daysAgo of [1, 2, 3, 6, 8, 13, 20, 40, 75, 200, 380, 500]) {
      const day = shiftDays(today, -daysAgo);
      const res = await save(traveller, {
        latitude: 20.3,
        longitude: 85.8,
        placeName: `d-${daysAgo}`,
        capturedAt: localInstant(day, 12, 0, IST).toISOString(),
      });
      assert.equal(res.status, 201, res.raw);
      savedOn.set(`d-${daysAgo}`, day);
    }
  });

  const within = (range: { startDate: string; endDate: string }) =>
    [...savedOn].filter(([, day]) => day >= range.startDate && day <= range.endDate).map(([name]) => name);

  for (const period of PERIODS) {
    test(`${period}: only that period's saved locations, oldest first`, async () => {
      const range = expectedRange(period, localToday(IST));
      const found = await names(traveller, { ...range, utcOffsetMinutes: IST });
      const expected = within(range).sort((a, b) => savedOn.get(a)!.localeCompare(savedOn.get(b)!));
      assert.deepEqual(found, expected, `${period} ${range.startDate}..${range.endDate}`);
    });
  }

  test("exact date and date range", async () => {
    const day = savedOn.get("d-3")!;
    assert.deepEqual(await names(traveller, { startDate: day, endDate: day, utcOffsetMinutes: IST }), ["d-3"]);
    // endDate defaults to startDate.
    assert.deepEqual(await names(traveller, { startDate: day, utcOffsetMinutes: IST }), ["d-3"]);
    const range = { startDate: savedOn.get("d-8")!, endDate: savedOn.get("d-2")!, utcOffsetMinutes: IST };
    assert.deepEqual(await names(traveller, range), ["d-8", "d-6", "d-3", "d-2"]);
  });

  test("dates are the user's local days, not UTC days", async () => {
    const zoneUser = await registerUser("Zones");
    // 2025-10-05 00:30 and 23:30 in India, then 00:01 on the 6th.
    for (const [placeName, capturedAt] of [
      ["early", "2025-10-04T19:00:00.000Z"],
      ["late", "2025-10-05T18:00:00.000Z"],
      ["next-day", "2025-10-05T18:31:00.000Z"],
    ]) {
      assert.equal((await save(zoneUser, { latitude: 1, longitude: 1, placeName, capturedAt })).status, 201);
    }
    const day = { startDate: "2025-10-05", endDate: "2025-10-05" };
    assert.deepEqual(await names(zoneUser, { ...day, utcOffsetMinutes: IST }), ["early", "late"]);
    assert.deepEqual(await names(zoneUser, { ...day, timeZone: "Asia/Kolkata" }), ["early", "late"]);
    // Without a zone the dates are UTC days: a different set, which is why the app sends one.
    assert.deepEqual(await names(zoneUser, day), ["late", "next-day"]);
  });

  test("an empty or future date returns no locations, not an error", async () => {
    const res = await search(traveller, { startDate: "2001-01-01", endDate: "2001-01-31", utcOffsetMinutes: IST });
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json.locations, []);
    assert.equal(res.json.hasMore, false);
    assert.deepEqual(res.json.range, { startDate: "2001-01-01", endDate: "2001-01-31" });
    const tomorrow = shiftDays(localToday(IST), 1);
    assert.deepEqual(await names(traveller, { startDate: tomorrow, utcOffsetMinutes: IST }), []);
  });

  test("invalid dates return 400 with a readable message", async () => {
    for (const startDate of ["2026-13-01", "2026-02-30", "05-10-2026", "05/10/2026", "abc", "2026-10-05T00:00:00Z", ""]) {
      const res = await search(traveller, { startDate, endDate: "2026-10-07" });
      assert.equal(res.status, 400, `${startDate}: ${res.raw}`);
      assert.equal(res.json.message, "Invalid date. Use the format YYYY-MM-DD.");
      assert.doesNotMatch(res.raw, /stack|\.ts:\d/i);
    }
    const onlyEnd = await search(traveller, { endDate: "2026-10-07" });
    assert.equal(onlyEnd.status, 400, onlyEnd.raw);
    for (const query of [{ timeZone: "Not/AZone" }, { utcOffsetMinutes: 5000 }, { utcOffsetMinutes: "abc" }]) {
      assert.equal((await search(traveller, { startDate: "2026-10-05", ...query })).status, 400, JSON.stringify(query));
    }
  });

  test("an inverted range, a range over a year, or mixing styles returns 400", async () => {
    const inverted = await search(traveller, { startDate: "2026-10-07", endDate: "2026-10-01" });
    assert.equal(inverted.status, 400, inverted.raw);
    assert.equal(inverted.json.message, "Invalid date range.");

    const tooLong = await search(traveller, { startDate: "2025-01-01", endDate: "2026-01-02" });
    assert.equal(tooLong.status, 400, tooLong.raw);
    assert.match(tooLong.json.message, /^Invalid date range/);
    // A whole leap year is still one year.
    assert.equal((await search(traveller, { startDate: "2024-01-01", endDate: "2024-12-31" })).status, 200);

    const mixed = await search(traveller, { startDate: "2026-10-01", since: new Date().toISOString() });
    assert.equal(mixed.status, 400, mixed.raw);
  });

  test("at most 50 results, with hasMore when there are more", async () => {
    const busy = await registerUser("Busy");
    const day = shiftDays(localToday(IST), -1);
    await prisma.locationHistory.createMany({
      data: Array.from({ length: 55 }, (_, i) => ({
        userId: busy.id,
        latitude: 1,
        longitude: 1,
        placeName: `stop-${i}`,
        capturedAt: localInstant(day, 8, i, IST),
      })),
    });

    const huge = await search(busy, { limit: 5000 });
    assert.equal(huge.status, 200, huge.raw);
    assert.equal(huge.json.locations.length, 50);
    assert.equal(huge.json.hasMore, true);

    const dated = await search(busy, { startDate: day, endDate: day, utcOffsetMinutes: IST, limit: 5000 });
    assert.equal(dated.json.locations.length, 50);
    assert.equal(dated.json.hasMore, true);
    // Oldest first, so the first 50 of the day are the ones returned.
    assert.equal(dated.json.locations[0].placeName, "stop-0");
    assert.equal(dated.json.locations[49].placeName, "stop-49");

    const few = await search(busy, { startDate: day, utcOffsetMinutes: IST, limit: 10 });
    assert.equal(few.json.locations.length, 10);
    assert.equal(few.json.hasMore, true);
    const dayBefore = await search(busy, { startDate: shiftDays(day, -1), utcOffsetMinutes: IST });
    assert.deepEqual(dayBefore.json.locations, []);
    assert.equal(dayBefore.json.hasMore, false);
  });

  test("recent history without dates stays newest first", async () => {
    const found = await names(traveller, {});
    assert.deepEqual(found.slice(0, 2), ["today", "d-1"]);
  });

  test("a date search only ever sees the signed-in user's locations", async () => {
    const range = { startDate: shiftDays(localToday(IST), -360), endDate: localToday(IST), utcOffsetMinutes: IST };
    assert.deepEqual(await names(other, range), []);
    assert.ok((await names(traveller, range)).length > 0);
    const spoof = await search(other, { ...range, userId: traveller.id });
    assert.equal(spoof.status, 400, spoof.raw);
    assert.doesNotMatch(spoof.raw, /d-1/);
  });

  test("a date search without a valid token returns 401", async () => {
    const qs = "?startDate=2026-10-05&endDate=2026-10-05";
    assert.equal((await call("GET", `/api/location/history${qs}`)).status, 401);
    assert.equal((await call("GET", `/api/location/history${qs}`, { token: "not-a-jwt" })).status, 401);
  });
});
