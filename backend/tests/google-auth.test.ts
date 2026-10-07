// Integration tests for "Continue with Google" (POST /api/auth/google).
// Runs the real app against the configured PostgreSQL database (DATABASE_URL). Google is replaced
// only at its signing key: tests sign ID tokens with their own RSA key, and the real verification
// (signature, issuer, audience, expiry) runs unchanged. Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import jwt from "jsonwebtoken";
import { createApp } from "../src/app";
import { verifyAccessToken } from "../src/lib/jwt";
import { setGoogleSigningKeysSource } from "../src/lib/google-token";
import { prisma } from "../src/lib/prisma";

const AUDIENCE = "child-assist-test-web-client.apps.googleusercontent.com";
const KID = "test-key";

const googleKey = generateKeyPairSync("rsa", { modulusLength: 2048 });
const attackerKey = generateKeyPairSync("rsa", { modulusLength: 2048 });

let server: Server;
let baseUrl: string;
let savedClientId: string | undefined;
const createdEmails: string[] = [];

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

function uniqueEmail(): string {
  const email = `google-${randomUUID()}@test.local`;
  createdEmails.push(email);
  return email;
}

/** A Google-style ID token. Defaults describe a valid token for AUDIENCE. */
function idToken(
  claims: Record<string, unknown>,
  { key = googleKey.privateKey, expiresInSec = 3600 }: { key?: typeof googleKey.privateKey; expiresInSec?: number } = {},
): string {
  const now = Math.floor(Date.now() / 1000);
  return jwt.sign(
    {
      iss: "https://accounts.google.com",
      aud: AUDIENCE,
      email_verified: true,
      iat: now - 60,
      exp: now + expiresInSec,
      ...claims,
    },
    key,
    { algorithm: "RS256", keyid: KID },
  );
}

function googleLogin(token: string, extra: Record<string, unknown> = {}) {
  return call("POST", "/api/auth/google", { body: { idToken: token, ...extra } });
}

function assertNoSecrets(raw: string): void {
  assert.ok(!/passwordHash|password_hash/i.test(raw), `response leaked a password hash: ${raw}`);
  assert.ok(!/googleSubject|google_subject/i.test(raw), `response leaked the Google subject: ${raw}`);
}

before(async () => {
  savedClientId = process.env.GOOGLE_WEB_CLIENT_ID;
  process.env.GOOGLE_WEB_CLIENT_ID = AUDIENCE;
  setGoogleSigningKeysSource(async () => ({
    [KID]: googleKey.publicKey.export({ type: "spki", format: "pem" }).toString(),
  }));
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(async () => {
  if (savedClientId === undefined) delete process.env.GOOGLE_WEB_CLIENT_ID;
  else process.env.GOOGLE_WEB_CLIENT_ID = savedClientId;
  setGoogleSigningKeysSource(null);
  await prisma.user.deleteMany({ where: { email: { in: createdEmails } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("POST /api/auth/google", () => {
  test("1/6. a valid token for a new Google account creates one password-less user and returns a Child Assist JWT", async () => {
    const email = uniqueEmail();
    const sub = `sub-${randomUUID()}`;
    const res = await googleLogin(idToken({ sub, email: email.toUpperCase(), name: "Mansi Patro" }));

    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(Object.keys(res.json.user).sort(), ["email", "id", "name"]);
    assert.equal(res.json.user.name, "Mansi Patro");
    assert.equal(res.json.user.email, email);
    assertNoSecrets(res.raw);

    // Our own JWT, identifying the user only through `sub`.
    const claims = verifyAccessToken(res.json.token);
    assert.equal(claims.sub, res.json.user.id);
    const decoded = jwt.decode(res.json.token) as Record<string, unknown>;
    assert.deepEqual(Object.keys(decoded).sort(), ["exp", "iat", "jti", "sub"]);

    const rows = await prisma.user.findMany({ where: { email } });
    assert.equal(rows.length, 1);
    assert.equal(rows[0].googleSubject, sub);
    assert.equal(rows[0].passwordHash, null);
  });

  test("5. the same Google account signs in to the same user, with no duplicate", async () => {
    const email = uniqueEmail();
    const sub = `sub-${randomUUID()}`;
    const first = await googleLogin(idToken({ sub, email, name: "First Name" }));
    // Google profile changes (even the email) do not create a new account: `sub` is the key.
    const second = await googleLogin(idToken({ sub, email: uniqueEmail(), name: "Renamed" }));

    assert.equal(first.status, 200, first.raw);
    assert.equal(second.status, 200, second.raw);
    assert.equal(second.json.user.id, first.json.user.id);
    assert.equal(second.json.user.name, "First Name");
    assert.equal(second.json.user.email, email);
    assert.notEqual(second.json.token, first.json.token);
    assert.equal(await prisma.user.count({ where: { googleSubject: sub } }), 1);
  });

  test("2. a malformed or forged token is rejected with 401", async () => {
    const email = uniqueEmail();
    for (const token of [
      "not-a-jwt",
      "a.b.c",
      idToken({ sub: "x", email }, { key: attackerKey.privateKey }),
      idToken({ sub: "x", email }).slice(0, -4) + "AAAA",
    ]) {
      const res = await googleLogin(token);
      assert.equal(res.status, 401, res.raw);
      assert.equal(res.json.message, "Google authentication failed.");
      assert.ok(!res.raw.includes(token), "the token must not be echoed back");
    }
    assert.equal(await prisma.user.count({ where: { email } }), 0);
  });

  test("3. an expired token is rejected with 401", async () => {
    const email = uniqueEmail();
    const res = await googleLogin(idToken({ sub: `sub-${randomUUID()}`, email }, { expiresInSec: -3600 }));
    assert.equal(res.status, 401, res.raw);
    assert.equal(await prisma.user.count({ where: { email } }), 0);
  });

  test("4. a token for another audience or issuer is rejected with 401", async () => {
    const email = uniqueEmail();
    const sub = `sub-${randomUUID()}`;
    for (const claims of [
      { aud: "some-other-app.apps.googleusercontent.com" },
      { iss: "https://evil.example.com" },
    ]) {
      const res = await googleLogin(idToken({ sub, email, ...claims }));
      assert.equal(res.status, 401, res.raw);
    }
    assert.equal(await prisma.user.count({ where: { email } }), 0);
  });

  test("an unverified Google email is never used to create or find an account", async () => {
    const email = uniqueEmail();
    const res = await googleLogin(idToken({ sub: `sub-${randomUUID()}`, email, email_verified: false }));
    assert.equal(res.status, 401, res.raw);
    assert.equal(await prisma.user.count({ where: { email } }), 0);
  });

  test("identity fields sent by the client are refused, not trusted", async () => {
    const email = uniqueEmail();
    const token = idToken({ sub: `sub-${randomUUID()}`, email });
    for (const extra of [{ email: "victim@example.com" }, { name: "x" }, { googleSubject: "x" }, { picture: "x" }]) {
      const res = await googleLogin(token, extra);
      assert.equal(res.status, 400, res.raw);
    }
    assert.equal((await call("POST", "/api/auth/google", { body: {} })).status, 400);
    assert.equal(await prisma.user.count({ where: { email } }), 0);
  });

  test("7. an existing password account with the same email is not merged or taken over", async () => {
    const email = uniqueEmail();
    const reg = await call("POST", "/api/auth/register", { body: { name: "Password User", email, password: "password123" } });
    assert.equal(reg.status, 201, reg.raw);
    const before = await prisma.user.findUniqueOrThrow({ where: { email } });

    const res = await googleLogin(idToken({ sub: `sub-${randomUUID()}`, email, name: "Attacker" }));
    assert.equal(res.status, 409, res.raw);
    assert.equal(res.json.code, "ACCOUNT_EXISTS_WITH_PASSWORD");
    assert.match(res.json.message, /already exists with this email/);
    assert.ok(!("token" in res.json));

    const afterRow = await prisma.user.findUniqueOrThrow({ where: { email } });
    assert.equal(afterRow.googleSubject, null);
    assert.equal(afterRow.passwordHash, before.passwordHash);
    assert.equal(afterRow.name, "Password User");
    assert.equal(await prisma.user.count({ where: { email } }), 1);

    // 8. and its password login still works.
    const login = await call("POST", "/api/auth/login", { body: { email, password: "password123" } });
    assert.equal(login.status, 200, login.raw);
    assert.equal(login.json.user.id, before.id);
  });

  test("9. password login on a Google-only account gets a controlled 'use Google' error", async () => {
    const email = uniqueEmail();
    assert.equal((await googleLogin(idToken({ sub: `sub-${randomUUID()}`, email }))).status, 200);

    const res = await call("POST", "/api/auth/login", { body: { email, password: "password123" } });
    assert.equal(res.status, 401, res.raw);
    assert.equal(res.json.code, "USE_GOOGLE_SIGN_IN");
    assert.equal(res.json.message, "This account uses Google Sign-In. Please continue with Google.");
    assert.ok(!("token" in res.json));

    // Registering a password account over it is refused too.
    const reg = await call("POST", "/api/auth/register", { body: { name: "X", email, password: "password123" } });
    assert.equal(reg.status, 409, reg.raw);
  });

  test("10. a Google-created user can use their profile like any other user", async () => {
    const email = uniqueEmail();
    const login = await googleLogin(idToken({ sub: `sub-${randomUUID()}`, email, name: "Mansi Patro" }));
    assert.equal(login.status, 200, login.raw);

    const profile = await call("GET", "/api/profile", { token: login.json.token });
    assert.equal(profile.status, 200, profile.raw);
    assert.deepEqual(profile.json, {
      user: {
        id: login.json.user.id,
        name: "Mansi Patro",
        email,
        profileImageUrl: null,
        permissionOnboardingCompleted: false,
      },
    });
    assertNoSecrets(profile.raw);

    const me = await call("GET", "/api/auth/me", { token: login.json.token });
    assert.equal(me.status, 200);
    assert.equal(me.json.user.email, email);
  });

  test("answers 503, not 500, when the server has no Google client ID configured", async () => {
    const email = uniqueEmail();
    delete process.env.GOOGLE_WEB_CLIENT_ID;
    try {
      const res = await googleLogin(idToken({ sub: `sub-${randomUUID()}`, email }));
      assert.equal(res.status, 503, res.raw);
      assert.equal(res.json.code, "GOOGLE_SSO_UNAVAILABLE");
    } finally {
      process.env.GOOGLE_WEB_CLIENT_ID = AUDIENCE;
    }
  });
});
