// Integration tests for the first-time permission onboarding flag (users.permission_onboarding_completed).
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
  email: string;
  token: string;
}

let userA: TestUser;
let userB: TestUser;

const ONBOARDING = "/api/profile/permission-onboarding";

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
  return registerVerifiedUser(call, name, `onboarding-${randomUUID()}@test.local`);
}

async function onboardingFlag(user: TestUser): Promise<boolean> {
  const res = await call("GET", "/api/profile", { token: user.token });
  assert.equal(res.status, 200, res.raw);
  return res.json.user.permissionOnboardingCompleted;
}

function decodeJwtPayload(token: string): unknown {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
}

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  userA = await registerUser("User A");
  userB = await registerUser("User B");
});

after(async () => {
  await prisma.user.deleteMany({ where: { id: { in: [userA?.id, userB?.id].filter(Boolean) } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("permission onboarding", () => {
  test("1-2. a new user starts with onboarding not completed, returned by GET /api/profile", async () => {
    const res = await call("GET", "/api/profile", { token: userA.token });
    assert.equal(res.status, 200);
    assert.equal(res.json.user.permissionOnboardingCompleted, false);
    assert.ok(!/passwordHash|password_hash/i.test(res.raw), `response leaked a password hash: ${res.raw}`);

    const row = await prisma.user.findUniqueOrThrow({ where: { id: userA.id } });
    assert.equal(row.permissionOnboardingCompleted, false);
  });

  test("3. an authenticated user can mark onboarding completed (and back)", async () => {
    const done = await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: true } });
    assert.equal(done.status, 200, done.raw);
    assert.equal(done.json.user.id, userA.id);
    assert.equal(done.json.user.permissionOnboardingCompleted, true);
    assert.ok(!/passwordHash|password_hash/i.test(done.raw));
    assert.equal(await onboardingFlag(userA), true);

    const undone = await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: false } });
    assert.equal(undone.json.user.permissionOnboardingCompleted, false);
    await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: true } });
  });

  test("4. requests without a valid JWT get 401", async () => {
    assert.equal((await call("PATCH", ONBOARDING, { body: { completed: true } })).status, 401);
    assert.equal(
      (await call("PATCH", ONBOARDING, { token: "not-a-jwt", body: { completed: true } })).status,
      401,
    );
  });

  test("5-6. unknown fields, a client-supplied user ID and bad values get 400", async () => {
    const invalidBodies: unknown[] = [
      { userId: userB.id },
      { completed: true, userId: userB.id },
      { completed: true, id: userB.id },
      { completed: true, name: "x" },
      { completed: "true" },
      { completed: 1 },
      { completed: null },
      {},
      [true],
    ];
    for (const body of invalidBodies) {
      const res = await call("PATCH", ONBOARDING, { token: userB.token, body });
      assert.equal(res.status, 400, `expected 400 for ${JSON.stringify(body)}, got ${res.raw}`);
    }
    assert.equal(await onboardingFlag(userB), false, "rejected requests changed nothing");
  });

  test("7. user A cannot modify user B's onboarding state", async () => {
    // A's token only ever addresses A, whatever the body or path says.
    await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: false } });
    const byPath = await call("PATCH", `${ONBOARDING}/${userB.id}`, {
      token: userA.token,
      body: { completed: true },
    });
    assert.equal(byPath.status, 404);
    assert.equal(await onboardingFlag(userB), false);

    await call("PATCH", ONBOARDING, { token: userB.token, body: { completed: true } });
    assert.equal(await onboardingFlag(userB), true);
    assert.equal(await onboardingFlag(userA), false);
    await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: true } });
  });

  test("8. permission records are left intact by onboarding changes", async () => {
    const statuses = {
      LOCATION: "DENIED",
      MICROPHONE: "DENIED",
      CAMERA: "GRANTED",
      PHOTOS: "LIMITED",
      NOTIFICATIONS: "DENIED",
    };
    for (const [permission, status] of Object.entries(statuses)) {
      const res = await call("PATCH", `/api/permissions/${permission}`, { token: userA.token, body: { status } });
      assert.equal(res.status, 200, res.raw);
    }
    await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: false } });
    await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: true } });

    const list = await call("GET", "/api/permissions", { token: userA.token });
    const byType = Object.fromEntries(
      list.json.permissions.map((p: { permission: string; status: string }) => [p.permission, p.status]),
    );
    assert.deepEqual(byType, { ...statuses, DOCUMENTS: "UNKNOWN", CONTACTS: "UNKNOWN" });
    assert.equal(await prisma.userPermission.count({ where: { userId: userA.id } }), 5);
  });

  test("9. profile edits keep the onboarding state and vice versa", async () => {
    const edited = await call("PATCH", "/api/profile", { token: userA.token, body: { name: "Renamed A" } });
    assert.equal(edited.status, 200, edited.raw);
    assert.equal(edited.json.user.permissionOnboardingCompleted, true);

    const flagged = await call("PATCH", ONBOARDING, { token: userA.token, body: { completed: true } });
    assert.equal(flagged.json.user.name, "Renamed A");
    assert.equal(flagged.json.user.email, userA.email);

    // The general profile PATCH cannot be used to flip the flag.
    const sneaky = await call("PATCH", "/api/profile", {
      token: userA.token,
      body: { name: "x", permissionOnboardingCompleted: false },
    });
    assert.equal(sneaky.status, 400);
    assert.equal(await onboardingFlag(userA), true);
  });

  test("the flag survives logout and a new login, and is not in the JWT", async () => {
    await call("POST", "/api/auth/logout", { token: userA.token });
    const login = await call("POST", "/api/auth/login", {
      body: { email: userA.email, password: "password123" },
    });
    assert.equal(login.status, 200, login.raw);
    assert.ok(
      !/permission|onboarding/i.test(JSON.stringify(decodeJwtPayload(login.json.token))),
      "no permission data in the JWT",
    );
    assert.equal(await onboardingFlag({ ...userA, token: login.json.token }), true);
  });
});
