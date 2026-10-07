// Integration tests for Automatic Location History on the existing location API: the `source`
// field, server-side duplicate protection, validation, per-user rate limiting, and automatic
// records in date searches. Runs the real app against the configured PostgreSQL database
// (DATABASE_URL) and removes the users it creates afterwards. Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, afterEach, before, beforeEach, describe, test } from "node:test";
import jwt from "jsonwebtoken";
import { LocationSource } from "../generated/prisma/client";
import { createApp } from "../src/app";
import { prisma } from "../src/lib/prisma";
import { distanceMeters } from "../src/lib/geo";
import { resetRateLimits } from "../src/middleware/rate-limit.middleware";
import { registerVerifiedUser } from "./support/auth";
import { PERIODS, expectedRange, localInstant, localToday, shiftDays } from "./support/dates";

let server: Server;
let baseUrl: string;

interface TestUser {
  id: string;
  token: string;
}

let userA: TestUser;
let userB: TestUser;
const createdUserIds: string[] = [];

// Home and School in Bhubaneswar, about 6.6 km apart.
const HOME = { latitude: 20.2961, longitude: 85.8245 };
const SCHOOL = { latitude: 20.3555, longitude: 85.8195 };

async function call(
  method: string,
  path: string,
  { token, body, rawBody }: { token?: string; body?: unknown; rawBody?: string } = {},
): Promise<{ status: number; json: any; raw: string }> {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
  const raw = await res.text();
  return { status: res.status, json: raw ? JSON.parse(raw) : null, raw };
}

async function registerUser(name: string): Promise<TestUser> {
  const user = await registerVerifiedUser(call, name, `auto-loc-${randomUUID()}@test.local`);
  createdUserIds.push(user.id);
  return { id: user.id, token: user.token };
}

const minutesAgo = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();

/** A point [meters] north of [from]. */
function north(from: { latitude: number; longitude: number }, meters: number) {
  return { latitude: from.latitude + meters / 111_195, longitude: from.longitude };
}

function auto(user: TestUser, point: { latitude: number; longitude: number }, capturedAt: string, extra: Record<string, unknown> = {}) {
  return call("POST", "/api/location", { token: user.token, body: { ...point, capturedAt, source: "AUTOMATIC", ...extra } });
}

async function rows(user: TestUser) {
  return prisma.locationHistory.findMany({ where: { userId: user.id }, orderBy: { capturedAt: "asc" } });
}

async function clear(...users: TestUser[]) {
  await prisma.locationHistory.deleteMany({ where: { userId: { in: users.map((u) => u.id) } } });
}

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  userA = await registerUser("Auto A");
  userB = await registerUser("Auto B");
});

beforeEach(async () => {
  resetRateLimits();
  await clear(userA, userB);
});

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: createdUserIds } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("automatic location: saving", () => {
  test("an automatic location is created with source AUTOMATIC and the user's place details", async () => {
    const capturedAt = minutesAgo(3);
    const res = await auto(userA, HOME, capturedAt, { placeName: "Home", city: "Bhubaneswar" });
    assert.equal(res.status, 201, res.raw);
    assert.equal(res.json.saved, true);
    assert.equal(res.json.location.source, "AUTOMATIC");
    assert.equal(res.json.location.placeName, "Home");
    assert.equal(res.json.location.capturedAt, capturedAt);
    assert.ok(!res.raw.includes(userA.id), "the owner id is never returned");
    const stored = await rows(userA);
    assert.equal(stored.length, 1);
    assert.equal(stored[0].source, LocationSource.AUTOMATIC);
    assert.equal(stored[0].userId, userA.id);
  });

  test("a manual location still works and is never treated as a duplicate", async () => {
    const body = { ...HOME, capturedAt: minutesAgo(2) };
    const first = await call("POST", "/api/location", { token: userA.token, body });
    const second = await call("POST", "/api/location", { token: userA.token, body: { ...body, source: "MANUAL" } });
    assert.equal(first.status, 201, first.raw);
    assert.equal(second.status, 201, second.raw);
    assert.equal(first.json.location.source, "MANUAL");
    assert.equal((await rows(userA)).length, 2, "the user asked twice, so both are kept");
  });

  test("geocoder failure: coordinates alone are saved", async () => {
    const res = await auto(userA, SCHOOL, minutesAgo(1), { placeName: null, address: null, city: null });
    assert.equal(res.status, 201, res.raw);
    assert.equal(res.json.location.placeName, null);
    assert.equal(res.json.location.latitude, SCHOOL.latitude);
  });
});

describe("automatic location: duplicate protection", () => {
  test("the same point sent again (a retry) is not stored twice", async () => {
    const capturedAt = minutesAgo(10);
    assert.equal((await auto(userA, HOME, capturedAt)).status, 201);
    const retry = await auto(userA, HOME, capturedAt);
    assert.equal(retry.status, 200, retry.raw);
    assert.deepEqual(retry.json, { saved: false, reason: "duplicate" });
    assert.equal((await rows(userA)).length, 1);
  });

  test("a nearby point within the time threshold is a duplicate", async () => {
    assert.equal((await auto(userA, HOME, minutesAgo(10))).status, 201);
    // 40 m away, 3 minutes later: GPS drift at the same place.
    const res = await auto(userA, north(HOME, 40), minutesAgo(7));
    assert.equal(res.json.saved, false);
    assert.equal((await rows(userA)).length, 1);
  });

  test("significant movement is accepted, even within the time threshold", async () => {
    assert.equal((await auto(userA, HOME, minutesAgo(10))).status, 201);
    const moved = await auto(userA, north(HOME, 250), minutesAgo(8));
    assert.equal(moved.status, 201, moved.raw);
    const school = await auto(userA, SCHOOL, minutesAgo(6));
    assert.equal(school.status, 201, school.raw);
    assert.equal((await rows(userA)).length, 3);
  });

  test("the same place after the time threshold is a new visit", async () => {
    assert.equal((await auto(userA, HOME, minutesAgo(60))).status, 201);
    const later = await auto(userA, HOME, minutesAgo(30));
    assert.equal(later.status, 201, later.raw);
    assert.equal((await rows(userA)).length, 2);
  });

  test("a queued point arriving after newer ones is still checked against its neighbours", async () => {
    assert.equal((await auto(userA, HOME, minutesAgo(20))).status, 201);
    assert.equal((await auto(userA, SCHOOL, minutesAgo(5))).status, 201);
    // A late retry of the Home point (1 minute after it, same place): duplicate of Home, not of School.
    const late = await auto(userA, north(HOME, 10), minutesAgo(19));
    assert.equal(late.json.saved, false);
    assert.equal((await rows(userA)).length, 2);
  });

  test("an automatic point next to a manual one is a duplicate too", async () => {
    const manual = await call("POST", "/api/location", { token: userA.token, body: { ...HOME, capturedAt: minutesAgo(4) } });
    assert.equal(manual.status, 201);
    assert.equal((await auto(userA, HOME, minutesAgo(3))).json.saved, false);
  });

  test("another user's locations never count as duplicates", async () => {
    const capturedAt = minutesAgo(5);
    assert.equal((await auto(userA, HOME, capturedAt)).status, 201);
    const b = await auto(userB, HOME, capturedAt);
    assert.equal(b.status, 201, b.raw);
    assert.equal((await rows(userB)).length, 1);
  });

  test("the same point uploaded concurrently is stored once", async () => {
    const capturedAt = minutesAgo(2);
    const results = await Promise.all(Array.from({ length: 5 }, () => auto(userA, SCHOOL, capturedAt)));
    assert.equal(results.filter((r) => r.status === 201).length, 1, results.map((r) => r.raw).join("\n"));
    assert.equal(results.filter((r) => r.json.saved === false).length, 4);
    assert.equal((await rows(userA)).length, 1);
  });

  test("thresholds follow the configuration", async () => {
    const original = process.env.AUTO_LOCATION_MIN_DISTANCE_METERS;
    process.env.AUTO_LOCATION_MIN_DISTANCE_METERS = "500";
    try {
      assert.equal((await auto(userA, HOME, minutesAgo(10))).status, 201);
      // 250 m is significant by default, but not with a 500 m threshold.
      assert.equal((await auto(userA, north(HOME, 250), minutesAgo(8))).json.saved, false);
    } finally {
      if (original === undefined) delete process.env.AUTO_LOCATION_MIN_DISTANCE_METERS;
      else process.env.AUTO_LOCATION_MIN_DISTANCE_METERS = original;
    }
  });

  test("distance helper is accurate enough for the threshold", () => {
    const d = distanceMeters(HOME, north(HOME, 100));
    assert.ok(Math.abs(d - 100) < 1, `got ${d}`);
    assert.ok(Math.abs(distanceMeters(HOME, SCHOOL) - 6630) < 100);
  });
});

describe("automatic location: validation and authentication", () => {
  test("authentication is required; invalid and expired tokens are refused", async () => {
    const body = { ...HOME, capturedAt: minutesAgo(1), source: "AUTOMATIC" };
    assert.equal((await call("POST", "/api/location", { body })).status, 401);
    assert.equal((await call("POST", "/api/location", { body, token: "not-a-jwt" })).status, 401);
    const forged = jwt.sign({}, "x".repeat(40), { subject: userA.id, algorithm: "HS256" });
    assert.equal((await call("POST", "/api/location", { body, token: forged })).status, 401);
    const expired = jwt.sign({ exp: Math.floor(Date.now() / 1000) - 60 }, process.env.JWT_SECRET!, {
      subject: userA.id,
      algorithm: "HS256",
    });
    const res = await call("POST", "/api/location", { body, token: expired });
    assert.equal(res.status, 401);
    assert.equal(res.json.message, "Invalid or expired token");
    assert.equal((await rows(userA)).length, 0);
  });

  test("a userId in the body is rejected, never used", async () => {
    const res = await auto(userA, HOME, minutesAgo(1), { userId: userB.id });
    assert.equal(res.status, 400, res.raw);
    assert.equal((await rows(userA)).length + (await rows(userB)).length, 0);
  });

  test("invalid coordinates, source and capturedAt are rejected", async () => {
    const cases: Array<[string, Record<string, unknown>]> = [
      ["latitude", { latitude: 91, longitude: 85 }],
      ["latitude", { latitude: "20.1", longitude: 85 }],
      ["longitude", { latitude: 20, longitude: -181 }],
      ["source", { ...HOME, source: "BACKGROUND" }],
      ["source", { ...HOME, source: "automatic" }],
      ["capturedAt", { ...HOME, capturedAt: "yesterday" }],
      ["capturedAt", { ...HOME, capturedAt: new Date(Date.now() + 3_600_000).toISOString() }],
      ["capturedAt", { ...HOME, capturedAt: "1999-12-31T23:00:00Z" }],
      // Automatic points from a stale queue (default limit 7 days) would rewrite past days.
      ["capturedAt", { ...HOME, capturedAt: new Date(Date.now() - 8 * 86_400_000).toISOString() }],
    ];
    for (const [field, body] of cases) {
      const res = await call("POST", "/api/location", {
        token: userA.token,
        body: { capturedAt: minutesAgo(1), source: "AUTOMATIC", ...body },
      });
      assert.equal(res.status, 400, `${JSON.stringify(body)} -> ${res.raw}`);
      assert.ok(res.json.errors.some((e: { field: string }) => e.field === field), res.raw);
    }
    // An old manual save is still allowed (e.g. the clock was fixed later); only automatic is limited.
    const manual = await call("POST", "/api/location", {
      token: userA.token,
      body: { ...HOME, capturedAt: new Date(Date.now() - 8 * 86_400_000).toISOString() },
    });
    assert.equal(manual.status, 201, manual.raw);
  });

  test("malformed requests return 400 without echoing the body", async () => {
    const res = await call("POST", "/api/location", { token: userA.token, rawBody: '{"latitude": 20.29, ' });
    assert.equal(res.status, 400);
    assert.ok(!res.raw.includes("20.29"));
    const array = await call("POST", "/api/location", { token: userA.token, body: [HOME] });
    assert.equal(array.status, 400);
  });

  test("an unexpected server failure is a generic 500 and logs no coordinates", async () => {
    const original = prisma.$transaction;
    const logged: string[] = [];
    const originalError = console.error;
    console.error = (...args: unknown[]) => logged.push(args.map(String).join(" "));
    // A database error whose message quotes the query arguments, as Prisma's can.
    (prisma as unknown as { $transaction: unknown }).$transaction = async () => {
      throw new Error("Invalid invocation: { latitude: 12.3456789, longitude: 76.5432101 }");
    };
    try {
      const res = await auto(userA, { latitude: 12.3456789, longitude: 76.5432101 }, minutesAgo(1));
      assert.equal(res.status, 500);
      assert.deepEqual(res.json, { message: "Internal server error" });
    } finally {
      (prisma as unknown as { $transaction: unknown }).$transaction = original;
      console.error = originalError;
    }
    assert.ok(logged.length > 0);
    assert.ok(!logged.join("\n").includes("12.345"), "coordinates must not be logged");
    assert.ok(!logged.join("\n").includes("76.543"), "coordinates must not be logged");
  });
});

describe("automatic location: rate limiting", () => {
  test("too many uploads from one account get 429, other accounts are unaffected", async () => {
    const original = process.env.LOCATION_RATE_LIMIT_MAX;
    process.env.LOCATION_RATE_LIMIT_MAX = "3";
    try {
      for (let i = 0; i < 3; i++) {
        const res = await auto(userA, north(HOME, i * 1000), minutesAgo(30 - i * 10));
        assert.equal(res.status, 201, res.raw);
      }
      const limited = await auto(userA, SCHOOL, minutesAgo(1));
      assert.equal(limited.status, 429);
      assert.equal(limited.json.code, "RATE_LIMITED");
      assert.equal((await auto(userB, SCHOOL, minutesAgo(1))).status, 201);
      // Reading history is not limited by uploads.
      assert.equal((await call("GET", "/api/location/history", { token: userA.token })).status, 200);
    } finally {
      if (original === undefined) delete process.env.LOCATION_RATE_LIMIT_MAX;
      else process.env.LOCATION_RATE_LIMIT_MAX = original;
    }
  });
});

describe("automatic location: history and date search", () => {
  const OFFSET = 330; // India, UTC+05:30
  const today = () => localToday(OFFSET);

  async function seed(user: TestUser, source: LocationSource, date: string, hours: number, placeName: string) {
    await prisma.locationHistory.create({
      data: {
        userId: user.id,
        source,
        ...HOME,
        placeName,
        capturedAt: localInstant(date, hours, 0, OFFSET),
      },
    });
  }

  async function search(user: TestUser, query: Record<string, string>) {
    const res = await call(
      "GET",
      `/api/location/history?${new URLSearchParams({ utcOffsetMinutes: String(OFFSET), ...query })}`,
      { token: user.token },
    );
    return res;
  }

  test("automatic and manual records are returned together, oldest first, and can be filtered", async () => {
    const day = shiftDays(today(), -1);
    await seed(userA, LocationSource.AUTOMATIC, day, 8, "Home");
    await seed(userA, LocationSource.MANUAL, day, 9, "School gate");
    await seed(userA, LocationSource.AUTOMATIC, day, 13, "Restaurant");
    await seed(userB, LocationSource.AUTOMATIC, day, 10, "B's place");

    const both = await search(userA, { startDate: day });
    assert.equal(both.status, 200, both.raw);
    assert.deepEqual(both.json.locations.map((l: any) => [l.placeName, l.source]), [
      ["Home", "AUTOMATIC"],
      ["School gate", "MANUAL"],
      ["Restaurant", "AUTOMATIC"],
    ]);
    assert.ok(!both.raw.includes("B's place"), "another user's history is never included");

    const onlyAuto = await search(userA, { startDate: day, source: "AUTOMATIC" });
    assert.deepEqual(onlyAuto.json.locations.map((l: any) => l.placeName), ["Home", "Restaurant"]);
    const onlyManual = await search(userA, { startDate: day, source: "MANUAL" });
    assert.deepEqual(onlyManual.json.locations.map((l: any) => l.placeName), ["School gate"]);
    assert.equal((await search(userA, { source: "SOMETIMES" })).status, 400);
    assert.equal((await search(userA, { startDate: day, userId: userB.id })).status, 400);
  });

  test("automatic records appear in every period: today, yesterday ... this year, last year", async () => {
    for (const period of PERIODS) {
      await clear(userA);
      const range = expectedRange(period, today());
      await seed(userA, LocationSource.AUTOMATIC, range.endDate, 0, `in ${period}`);
      await seed(userA, LocationSource.AUTOMATIC, shiftDays(range.startDate, -1), 23, "just before");
      const res = await search(userA, range);
      assert.equal(res.status, 200, res.raw);
      assert.deepEqual(res.json.locations.map((l: any) => l.placeName), [`in ${period}`], period);
    }
  });

  test("custom date, custom range, future date and empty history", async () => {
    const day = shiftDays(today(), -10);
    await seed(userA, LocationSource.AUTOMATIC, day, 9, "Park");
    await seed(userA, LocationSource.AUTOMATIC, shiftDays(day, 2), 9, "Library");
    assert.deepEqual((await search(userA, { startDate: day })).json.locations.map((l: any) => l.placeName), ["Park"]);
    const range = await search(userA, { startDate: day, endDate: shiftDays(day, 3) });
    assert.deepEqual(range.json.locations.map((l: any) => l.placeName), ["Park", "Library"]);
    const future = await search(userA, { startDate: shiftDays(today(), 3) });
    assert.equal(future.status, 200);
    assert.deepEqual(future.json.locations, []);
    const empty = await search(userB, { startDate: day });
    assert.deepEqual(empty.json, { locations: [], hasMore: false, range: { startDate: day, endDate: day } });
  });

  test("more than 50 automatic records: 50 returned with hasMore", async () => {
    const day = shiftDays(today(), -1);
    await prisma.locationHistory.createMany({
      data: Array.from({ length: 55 }, (_, i) => ({
        userId: userA.id,
        source: LocationSource.AUTOMATIC,
        ...north(HOME, i * 200),
        capturedAt: localInstant(day, 0, 5 + i * 10, OFFSET),
      })),
    });
    const res = await search(userA, { startDate: day });
    assert.equal(res.json.locations.length, 50);
    assert.equal(res.json.hasMore, true);
  });

  test("deleting history removes automatic records too, only for the signed-in user", async () => {
    await seed(userA, LocationSource.AUTOMATIC, today(), 0, "A");
    await seed(userB, LocationSource.AUTOMATIC, today(), 0, "B");
    const res = await call("DELETE", "/api/location/history", { token: userA.token });
    assert.equal(res.json.deleted, 1);
    assert.equal((await rows(userB)).length, 1);
  });
});

afterEach(() => resetRateLimits());
