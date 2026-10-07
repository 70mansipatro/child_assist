// Integration tests for the Phase 3 profile and permission APIs.
// Runs the real app against the configured PostgreSQL database (DATABASE_URL) and removes
// the users it creates afterwards. Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import { createApp } from "../src/app";
import { prisma } from "../src/lib/prisma";

let server: Server;
let baseUrl: string;

interface TestUser {
  id: string;
  email: string;
  token: string;
}

let userA: TestUser;
let userB: TestUser;

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
  const email = `phase3-${randomUUID()}@test.local`;
  const res = await call("POST", "/api/auth/register", {
    body: { name, email, password: "password123" },
  });
  assert.equal(res.status, 201, res.raw);
  return { id: res.json.user.id, email, token: res.json.token };
}

function assertNoSecrets(raw: string): void {
  assert.ok(!/passwordHash|password_hash/i.test(raw), `response leaked a password hash: ${raw}`);
  assert.ok(!/"token"/.test(raw), `response leaked a token: ${raw}`);
}

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  userA = await registerUser("User A");
  userB = await registerUser("User B");
});

after(async () => {
  // Cascade delete also removes their user_permissions rows.
  await prisma.user.deleteMany({ where: { id: { in: [userA?.id, userB?.id].filter(Boolean) } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("profile", () => {
  test("A. GET /api/profile with a valid JWT returns the safe profile", async () => {
    const res = await call("GET", "/api/profile", { token: userA.token });
    assert.equal(res.status, 200);
    assert.deepEqual(res.json, {
      user: {
        id: userA.id,
        name: "User A",
        email: userA.email,
        profileImageUrl: null,
        permissionOnboardingCompleted: false,
      },
    });
    assertNoSecrets(res.raw);
  });

  test("B. GET /api/profile without a JWT or with a bad JWT is rejected", async () => {
    assert.equal((await call("GET", "/api/profile")).status, 401);
    assert.equal((await call("GET", "/api/profile", { token: "not-a-jwt" })).status, 401);
  });

  test("C. PATCH /api/profile updates name (trimmed) and image URL", async () => {
    const res = await call("PATCH", "/api/profile", {
      token: userA.token,
      body: { name: "  Mansi  ", profileImageUrl: "https://example.com/a.png" },
    });
    assert.equal(res.status, 200, res.raw);
    assert.equal(res.json.user.name, "Mansi");
    assert.equal(res.json.user.profileImageUrl, "https://example.com/a.png");
    assertNoSecrets(res.raw);

    const cleared = await call("PATCH", "/api/profile", {
      token: userA.token,
      body: { profileImageUrl: null },
    });
    assert.equal(cleared.status, 200);
    assert.equal(cleared.json.user.profileImageUrl, null);
    assert.equal(cleared.json.user.name, "Mansi");
  });

  test("D. PATCH /api/profile rejects invalid data with 400", async () => {
    const invalidBodies: unknown[] = [
      { name: "   " },
      { name: "x".repeat(101) },
      { name: 42 },
      {},
      { email: "hijack@example.com" },
      { name: "Ok", passwordHash: "x" },
      { id: userB.id, name: "Ok" },
      { profileImageUrl: "http://insecure.example.com/a.png" },
      { profileImageUrl: "javascript:alert(1)" },
      { profileImageUrl: "not a url" },
    ];
    for (const body of invalidBodies) {
      const res = await call("PATCH", "/api/profile", { token: userA.token, body });
      assert.equal(res.status, 400, `expected 400 for ${JSON.stringify(body)}, got ${res.raw}`);
    }
    assert.equal((await call("PATCH", "/api/profile", { body: { name: "x" } })).status, 401);

    // Nothing above changed the stored profile.
    const profile = await call("GET", "/api/profile", { token: userA.token });
    assert.equal(profile.json.user.name, "Mansi");
    assert.equal(profile.json.user.email, userA.email);
  });
});

describe("permissions", () => {
  test("E. GET /api/permissions lists every permission, UNKNOWN by default", async () => {
    const res = await call("GET", "/api/permissions", { token: userB.token });
    assert.equal(res.status, 200);
    const types = res.json.permissions.map((p: { permission: string }) => p.permission);
    assert.deepEqual(types, ["LOCATION", "MICROPHONE", "CAMERA", "PHOTOS", "NOTIFICATIONS", "DOCUMENTS"]);
    for (const p of res.json.permissions) assert.equal(p.status, "UNKNOWN");
  });

  test("F. GET /api/permissions without a JWT is rejected", async () => {
    assert.equal((await call("GET", "/api/permissions")).status, 401);
    assert.equal((await call("PATCH", "/api/permissions/LOCATION", { body: { status: "GRANTED" } })).status, 401);
  });

  test("G. PATCH LOCATION upserts a single row", async () => {
    const first = await call("PATCH", "/api/permissions/LOCATION", {
      token: userA.token,
      body: { status: "GRANTED" },
    });
    assert.equal(first.status, 200, first.raw);
    assert.equal(first.json.permission, "LOCATION");
    assert.equal(first.json.status, "GRANTED");

    const second = await call("PATCH", "/api/permissions/LOCATION", {
      token: userA.token,
      body: { status: "LIMITED" },
    });
    assert.equal(second.json.status, "LIMITED");

    const rows = await prisma.userPermission.count({ where: { userId: userA.id, permission: "LOCATION" } });
    assert.equal(rows, 1, "exactly one row per user + permission");
  });

  test("H. PATCH MICROPHONE is stored and listed", async () => {
    const res = await call("PATCH", "/api/permissions/MICROPHONE", {
      token: userA.token,
      body: { status: "DENIED" },
    });
    assert.equal(res.status, 200);
    assert.deepEqual({ permission: res.json.permission, status: res.json.status }, {
      permission: "MICROPHONE",
      status: "DENIED",
    });

    const list = await call("GET", "/api/permissions", { token: userA.token });
    const byType = Object.fromEntries(
      list.json.permissions.map((p: { permission: string; status: string }) => [p.permission, p.status]),
    );
    assert.equal(byType.LOCATION, "LIMITED");
    assert.equal(byType.MICROPHONE, "DENIED");
    assert.equal(byType.CAMERA, "UNKNOWN");
  });

  test("I. Unknown permission names are rejected with 400", async () => {
    for (const name of ["BLUETOOTH", "location", "CONTACTS"]) {
      const res = await call("PATCH", `/api/permissions/${name}`, {
        token: userA.token,
        body: { status: "GRANTED" },
      });
      assert.equal(res.status, 400, `expected 400 for ${name}, got ${res.raw}`);
    }
  });

  test("J. Invalid statuses are rejected with 400", async () => {
    const invalidBodies: unknown[] = [
      { status: "ALLOWED" },
      { status: "granted" },
      { status: null },
      {},
      { status: "GRANTED", userId: userB.id },
    ];
    for (const body of invalidBodies) {
      const res = await call("PATCH", "/api/permissions/CAMERA", { token: userA.token, body });
      assert.equal(res.status, 400, `expected 400 for ${JSON.stringify(body)}, got ${res.raw}`);
    }
    const camera = await prisma.userPermission.findMany({ where: { permission: "CAMERA", userId: { in: [userA.id, userB.id] } } });
    assert.equal(camera.length, 0);
  });
});

describe("isolation", () => {
  test("K. User A cannot read or change User B's data", async () => {
    // B's view is unaffected by everything A did above.
    const bProfile = await call("GET", "/api/profile", { token: userB.token });
    assert.equal(bProfile.json.user.id, userB.id);
    assert.equal(bProfile.json.user.name, "User B");

    const bPerms = await call("GET", "/api/permissions", { token: userB.token });
    for (const p of bPerms.json.permissions) assert.equal(p.status, "UNKNOWN");

    // B writes; A's records stay as they were.
    await call("PATCH", "/api/permissions/LOCATION", { token: userB.token, body: { status: "DENIED" } });
    await call("PATCH", "/api/profile", { token: userB.token, body: { name: "Still B" } });

    const aPerms = await call("GET", "/api/permissions", { token: userA.token });
    const aLocation = aPerms.json.permissions.find((p: { permission: string }) => p.permission === "LOCATION");
    assert.equal(aLocation.status, "LIMITED");
    const aProfile = await call("GET", "/api/profile", { token: userA.token });
    assert.equal(aProfile.json.user.name, "Mansi");

    // There is no route that accepts a user ID.
    assert.equal((await call("GET", `/api/profile/${userB.id}`, { token: userA.token })).status, 404);
    assert.equal((await call("GET", `/api/permissions/${userB.id}`, { token: userA.token })).status, 404);
  });

  test("L. A full name is saved, and a userId in the request never changes whose profile it is", async () => {
    const renamed = await call("PATCH", "/api/profile", { token: userA.token, body: { name: "Mansi Patro" } });
    assert.equal(renamed.status, 200, renamed.raw);
    assert.equal(renamed.json.user.name, "Mansi Patro");
    assert.equal(renamed.json.user.id, userA.id);
    assertNoSecrets(renamed.raw);

    // Asking for B by query string still returns A: identity comes only from the JWT.
    const sneaky = await call("GET", `/api/profile?userId=${userB.id}`, { token: userA.token });
    assert.equal(sneaky.status, 200);
    assert.equal(sneaky.json.user.id, userA.id);
    assert.equal(sneaky.json.user.name, "Mansi Patro");
    assert.equal(sneaky.json.user.email, userA.email);

    const bProfile = await call("GET", "/api/profile", { token: userB.token });
    assert.equal(bProfile.json.user.name, "Still B");
  });

  test("Deleting a user cascades to their permission rows", async () => {
    const temp = await registerUser("Temp");
    await call("PATCH", "/api/permissions/CAMERA", { token: temp.token, body: { status: "GRANTED" } });
    assert.equal(await prisma.userPermission.count({ where: { userId: temp.id } }), 1);
    await prisma.user.delete({ where: { id: temp.id } });
    assert.equal(await prisma.userPermission.count({ where: { userId: temp.id } }), 0);

    // A token for a deleted account is rejected.
    assert.equal((await call("GET", "/api/profile", { token: temp.token })).status, 401);
  });
});
