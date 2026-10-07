// Integration tests for email verification with one-time codes: registration, verify-email,
// resend-verification and the login gate. Runs the real app against the configured PostgreSQL
// database (DATABASE_URL). Email is captured in memory (tests/support/auth.ts); nothing is sent,
// except one test that points SMTP at a closed local port to exercise delivery failure.
// Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, test } from "node:test";
import bcrypt from "bcryptjs";
import { createApp } from "../src/app";
import { setEmailSender } from "../src/lib/email";
import { verifyAccessToken } from "../src/lib/jwt";
import { prisma } from "../src/lib/prisma";
import { hashCode, INVALID_CODE } from "../src/modules/auth/email-verification.service";
import { emailsTo, latestCodeFor, registerVerifiedUser, sentEmails, TEST_PASSWORD } from "./support/auth";

let server: Server;
let baseUrl: string;
const createdEmails: string[] = [];
const responses: string[] = [];
const logLines: string[] = [];

// Everything the app logs while these tests run, to prove codes and SMTP secrets never appear.
const consoleMethods = ["log", "info", "warn", "error", "debug"] as const;
const originalConsole = Object.fromEntries(consoleMethods.map((m) => [m, console[m]]));
for (const method of consoleMethods) {
  console[method] = (...args: unknown[]) => {
    logLines.push(args.map(String).join(" "));
    originalConsole[method](...args);
  };
}

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
  responses.push(raw);
  return { status: res.status, json: raw ? JSON.parse(raw) : null, raw };
}

function uniqueEmail(): string {
  const email = `verify-${randomUUID()}@test.local`;
  createdEmails.push(email);
  return email;
}

const register = (email: string, password = TEST_PASSWORD, name = "Mansi") =>
  call("POST", "/api/auth/register", { body: { name, email, password } });
const verify = (email: string, code: string) => call("POST", "/api/auth/verify-email", { body: { email, code } });
const resend = (email: string) => call("POST", "/api/auth/resend-verification", { body: { email } });
const login = (email: string, password = TEST_PASSWORD) =>
  call("POST", "/api/auth/login", { body: { email, password } });

const userByEmail = (email: string) => prisma.user.findUniqueOrThrow({ where: { email } });
const codesOf = (userId: string) =>
  prisma.emailVerificationCode.findMany({ where: { userId }, orderBy: { createdAt: "asc" } });

/** Moves the user's codes into the past, as if [seconds] had passed since they were sent. */
async function age(userId: string, seconds: number): Promise<void> {
  await prisma.$executeRaw`
    UPDATE email_verification_codes SET created_at = created_at - make_interval(secs => ${seconds})
    WHERE user_id = ${userId}::uuid`;
}

/** A 6-digit code that is not [code]. */
const wrong = (code: string) => (code === "000000" ? "111111" : "000000");

/** True if [code] appears in [text] as a standalone number (not inside a UUID or hash). */
const containsCode = (text: string, code: string) => new RegExp(`(^|[^0-9A-Za-z])${code}([^0-9A-Za-z]|$)`).test(text);

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(async () => {
  // Security 21-22: no code that was ever emailed shows up in any response or log line.
  const codes = sentEmails.map((m) => m.text.match(/^(\d{6})$/m)?.[1]).filter((c): c is string => !!c);
  assert.ok(codes.length > 10, "the suite should have issued codes");
  for (const code of codes) {
    for (const raw of responses) assert.ok(!containsCode(raw, code), `a response leaked a code: ${raw}`);
    for (const line of logLines) assert.ok(!containsCode(line, code), `a log line leaked a code: ${line}`);
  }
  for (const method of consoleMethods) console[method] = originalConsole[method];

  await prisma.user.deleteMany({ where: { email: { in: createdEmails } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("registration", () => {
  test("1-6. creates an unverified user, stores only an HMAC of a fresh code, emails it, returns no JWT", async () => {
    const email = uniqueEmail();
    const res = await register(email);

    assert.equal(res.status, 201, res.raw);
    assert.deepEqual(res.json, { requiresEmailVerification: true, message: "Verification code sent to your email." });

    const user = await userByEmail(email);
    assert.equal(user.emailVerified, false);
    assert.equal(user.name, "Mansi");
    assert.ok(user.passwordHash && (await bcrypt.compare(TEST_PASSWORD, user.passwordHash)));

    // 5. One email, carrying the code and nothing sensitive.
    const mails = emailsTo(email);
    assert.equal(mails.length, 1);
    const [mail] = mails;
    assert.equal(mail.subject, "Verify your Child Assist account");
    const code = latestCodeFor(email);
    assert.match(code, /^\d{6}$/);
    assert.ok(mail.html.includes(code));
    assert.match(mail.text, /This code expires in 10 minutes\./);
    assert.match(mail.text, /If you did not create this account, you can ignore this email\./);
    for (const secret of [TEST_PASSWORD, user.id, user.passwordHash!, "token"]) {
      assert.ok(!mail.text.includes(secret) && !mail.html.includes(secret), `the email contains ${secret}`);
    }

    // 2-4. One stored code: an HMAC bound to this user, never the code itself.
    const codes = await codesOf(user.id);
    assert.equal(codes.length, 1);
    assert.equal(codes[0].codeHash, hashCode(user.id, code));
    assert.match(codes[0].codeHash, /^[0-9a-f]{64}$/);
    assert.ok(!containsCode(JSON.stringify(codes), code), "the plain code is stored");
    assert.equal(codes[0].attempts, 0);
    assert.equal(codes[0].consumedAt, null);
    const ttl = codes[0].expiresAt.getTime() - codes[0].createdAt.getTime();
    assert.equal(ttl, 10 * 60_000);
  });

  test("rejects malformed input without creating anything", async () => {
    const email = uniqueEmail();
    for (const body of [
      { name: "", email, password: TEST_PASSWORD },
      { name: "Mansi", email: "not-an-email", password: TEST_PASSWORD },
      { name: "Mansi", email, password: "short" },
      { name: "Mansi", email, password: "x".repeat(73) },
      { email, password: TEST_PASSWORD },
    ]) {
      const res = await call("POST", "/api/auth/register", { body });
      assert.equal(res.status, 400, res.raw);
    }
    assert.equal(await prisma.user.count({ where: { email } }), 0);
    assert.equal(emailsTo(email).length, 0);
  });

  test("normalises the email: stored lower-case, and verify/login accept any case", async () => {
    const email = uniqueEmail();
    assert.equal((await register(`  ${email.toUpperCase()} `)).status, 201);
    const user = await userByEmail(email);
    assert.equal(user.email, email);
    assert.equal((await verify(email.toUpperCase(), latestCodeFor(email))).status, 200);
    assert.equal((await login(email.toUpperCase())).status, 200);
  });

  test("registering an existing verified email answers the same, changes nothing and sends nothing", async () => {
    const email = uniqueEmail();
    const owner = await registerVerifiedUser(call, "Owner", email);
    const before = await userByEmail(email);
    const mailsBefore = emailsTo(email).length;

    const res = await register(email, "attacker-password", "Attacker");
    assert.equal(res.status, 201, res.raw);
    assert.deepEqual(res.json, { requiresEmailVerification: true, message: "Verification code sent to your email." });
    assert.equal(emailsTo(email).length, mailsBefore);

    const afterRow = await userByEmail(email);
    assert.equal(afterRow.passwordHash, before.passwordHash);
    assert.equal(afterRow.name, "Owner");
    assert.equal((await login(email)).json.user.id, owner.id);
    assert.equal((await login(email, "attacker-password")).status, 401);
  });

  test("re-registering an unverified email replaces its password only together with a new code", async () => {
    // Someone registers an address they do not own...
    const email = uniqueEmail();
    await register(email, "squatter-password", "Squatter");
    const user = await userByEmail(email);
    const squatterCode = latestCodeFor(email);

    // ...within the cooldown a second registration changes nothing...
    await register(email, "owner-password", "Owner");
    assert.equal(emailsTo(email).length, 1);
    assert.ok(await bcrypt.compare("squatter-password", (await userByEmail(email)).passwordHash!));

    // ...after it, the owner's registration replaces the credentials and the old code.
    await age(user.id, 61);
    await register(email, "owner-password", "Owner");
    assert.equal(emailsTo(email).length, 2);
    assert.equal((await verify(email, squatterCode)).status, 400);
    assert.equal((await verify(email, latestCodeFor(email))).status, 200);

    assert.equal((await login(email, "squatter-password")).status, 401);
    const ok = await login(email, "owner-password");
    assert.equal(ok.status, 200, ok.raw);
    assert.equal(ok.json.user.name, "Owner");
    assert.equal(await prisma.user.count({ where: { email } }), 1);
  });
});

describe("POST /api/auth/verify-email", () => {
  test("7, 10. the right code verifies the account once; the code cannot be reused", async () => {
    const email = uniqueEmail();
    await register(email);
    const code = latestCodeFor(email);

    const res = await verify(email, code);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json, { verified: true, message: "Email verified successfully." });

    const user = await userByEmail(email);
    assert.equal(user.emailVerified, true);
    const [stored] = await codesOf(user.id);
    assert.ok(stored.consumedAt, "the code is spent");

    const again = await verify(email, code);
    assert.equal(again.status, 400, again.raw);
    assert.equal(again.json.code, "INVALID_VERIFICATION_CODE");
  });

  test("8. a wrong code fails, counts an attempt and leaves the account unverified", async () => {
    const email = uniqueEmail();
    await register(email);
    const code = latestCodeFor(email);

    const res = await verify(email, wrong(code));
    assert.equal(res.status, 400, res.raw);
    assert.deepEqual(res.json, { message: INVALID_CODE, code: "INVALID_VERIFICATION_CODE" });

    const user = await userByEmail(email);
    assert.equal(user.emailVerified, false);
    assert.equal((await codesOf(user.id))[0].attempts, 1);
    // The right code still works afterwards.
    assert.equal((await verify(email, code)).status, 200);
  });

  test("9. an expired code fails even when correct", async () => {
    const email = uniqueEmail();
    await register(email);
    const user = await userByEmail(email);
    await prisma.emailVerificationCode.updateMany({
      where: { userId: user.id },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });

    const res = await verify(email, latestCodeFor(email));
    assert.equal(res.status, 400, res.raw);
    assert.equal(res.json.message, INVALID_CODE);
    assert.equal((await userByEmail(email)).emailVerified, false);
  });

  test("11. the fifth wrong attempt kills the code; four wrong then right still works", async () => {
    const email = uniqueEmail();
    await register(email);
    const code = latestCodeFor(email);
    for (let i = 0; i < 5; i++) assert.equal((await verify(email, wrong(code))).status, 400);

    const res = await verify(email, code);
    assert.equal(res.status, 400, res.raw);
    assert.equal((await userByEmail(email)).emailVerified, false);

    const other = uniqueEmail();
    await register(other);
    const otherCode = latestCodeFor(other);
    for (let i = 0; i < 4; i++) assert.equal((await verify(other, wrong(otherCode))).status, 400);
    assert.equal((await verify(other, otherCode)).status, 200);
  });

  test("parallel guesses cannot exceed the attempt limit", async () => {
    const email = uniqueEmail();
    await register(email);
    const code = latestCodeFor(email);
    const results = await Promise.all(Array.from({ length: 12 }, () => verify(email, wrong(code))));
    assert.ok(results.every((r) => r.status === 400));
    const user = await userByEmail(email);
    assert.equal((await codesOf(user.id))[0].attempts, 5);
    assert.equal((await verify(email, code)).status, 400);
  });

  test("12, 14. a newer code invalidates the previous one", async () => {
    const email = uniqueEmail();
    await register(email);
    const user = await userByEmail(email);
    const first = latestCodeFor(email);

    await age(user.id, 61);
    assert.equal((await resend(email)).status, 200);
    const second = latestCodeFor(email);

    assert.equal((await verify(email, first)).status, 400);
    assert.equal((await verify(email, second)).status, 200);
    assert.ok((await codesOf(user.id)).every((c) => c.consumedAt));
  });

  test("unknown, verified and Google accounts get the same failure", async () => {
    const verified = uniqueEmail();
    await registerVerifiedUser(call, "V", verified);
    const google = uniqueEmail();
    await prisma.user.create({
      data: { name: "G", email: google, googleSubject: `sub-${randomUUID()}`, emailVerified: true },
    });

    for (const email of [uniqueEmail(), verified, google]) {
      const res = await verify(email, "123456");
      assert.equal(res.status, 400, res.raw);
      assert.deepEqual(res.json, { message: INVALID_CODE, code: "INVALID_VERIFICATION_CODE" });
    }
  });

  test("rejects malformed codes without counting an attempt", async () => {
    const email = uniqueEmail();
    await register(email);
    for (const code of ["12345", "1234567", "abcdef", "12 456", ""]) {
      assert.equal((await verify(email, code)).status, 400, code);
    }
    // None of those counted as an attempt.
    const user = await userByEmail(email);
    assert.equal((await codesOf(user.id))[0].attempts, 0);
  });
});

describe("POST /api/auth/resend-verification", () => {
  test("13, 15. sends a new code after the cooldown; within it, sends nothing", async () => {
    const email = uniqueEmail();
    await register(email);
    const user = await userByEmail(email);

    // Straight after registering: the cooldown applies, but the answer is the same.
    const early = await resend(email);
    assert.equal(early.status, 200, early.raw);
    assert.deepEqual(early.json, { message: "If verification is required, a new code has been sent." });
    assert.equal(emailsTo(email).length, 1);
    assert.equal((await codesOf(user.id)).length, 1);

    await age(user.id, 61);
    assert.equal((await resend(email)).status, 200);
    assert.equal(emailsTo(email).length, 2);
    const codes = await codesOf(user.id);
    assert.equal(codes.length, 2);
    assert.ok(codes[0].consumedAt, "the old code is invalidated");
    assert.equal(codes[1].consumedAt, null);
  });

  test("caps codes at five per hour", async () => {
    const email = uniqueEmail();
    await register(email);
    const user = await userByEmail(email);
    for (let i = 0; i < 4; i++) {
      await age(user.id, 61);
      await resend(email);
    }
    assert.equal(emailsTo(email).length, 5);

    await age(user.id, 61);
    assert.equal((await resend(email)).status, 200);
    assert.equal(emailsTo(email).length, 5, "the sixth code within an hour is not sent");

    // Once the oldest falls out of the hour, sending resumes.
    await age(user.id, 60 * 60);
    await resend(email);
    assert.equal(emailsTo(email).length, 6);
  });

  test("16. unknown, verified and Google accounts get the same answer and no email", async () => {
    const verified = uniqueEmail();
    await registerVerifiedUser(call, "V", verified);
    const google = uniqueEmail();
    await prisma.user.create({
      data: { name: "G", email: google, googleSubject: `sub-${randomUUID()}`, emailVerified: true },
    });
    const unknown = uniqueEmail();
    const sentBefore = sentEmails.length;

    for (const email of [unknown, verified, google]) {
      const res = await resend(email);
      assert.equal(res.status, 200, res.raw);
      assert.deepEqual(res.json, { message: "If verification is required, a new code has been sent." });
    }
    assert.equal(sentEmails.length, sentBefore);
    assert.equal(await prisma.user.count({ where: { email: unknown } }), 0);
  });

  test("refuses a body naming anything but the email", async () => {
    const email = uniqueEmail();
    await register(email);
    const user = await userByEmail(email);
    const res = await call("POST", "/api/auth/resend-verification", { body: { email, userId: user.id } });
    assert.equal(res.status, 400, res.raw);
  });
});

describe("login", () => {
  test("17. an unverified account with the right password gets no JWT, just the verification signal", async () => {
    const email = uniqueEmail();
    await register(email);

    const res = await login(email);
    assert.equal(res.status, 403, res.raw);
    assert.deepEqual(res.json, {
      requiresEmailVerification: true,
      code: "EMAIL_NOT_VERIFIED",
      message: "Please verify your email before logging in.",
    });
    assert.ok(!/token/i.test(res.raw));
  });

  test("an unverified login sends a fresh code (after the cooldown); a wrong password reveals nothing", async () => {
    const email = uniqueEmail();
    await register(email);
    const user = await userByEmail(email);
    await age(user.id, 61);

    const bad = await login(email, "wrong-password");
    assert.equal(bad.status, 401, bad.raw);
    assert.deepEqual(bad.json, { message: "Invalid email or password" });
    assert.equal(emailsTo(email).length, 1);

    assert.equal((await login(email)).status, 403);
    assert.equal(emailsTo(email).length, 2);
    assert.equal((await verify(email, latestCodeFor(email))).status, 200);
  });

  test("18, 25. a verified account logs in and its JWT works on protected routes", async () => {
    const email = uniqueEmail();
    await register(email);
    await verify(email, latestCodeFor(email));

    const res = await login(email);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(Object.keys(res.json.user).sort(), ["email", "id", "name"]);
    assert.equal(verifyAccessToken(res.json.token).sub, res.json.user.id);

    const me = await call("GET", "/api/auth/me", { token: res.json.token });
    assert.equal(me.status, 200, me.raw);
    assert.equal(me.json.user.email, email);
    assert.equal((await call("GET", "/api/profile", { token: res.json.token })).status, 200);
    assert.equal((await call("GET", "/api/auth/me", { token: "not-a-jwt" })).status, 401);
  });

  test("19. a Google-only account is told to use Google and is never sent a code", async () => {
    const email = uniqueEmail();
    await prisma.user.create({
      data: { name: "G", email, googleSubject: `sub-${randomUUID()}`, emailVerified: true },
    });
    const res = await login(email);
    assert.equal(res.status, 401, res.raw);
    assert.equal(res.json.code, "USE_GOOGLE_SIGN_IN");
    assert.equal(emailsTo(email).length, 0);
    assert.equal((await userByEmail(email)).passwordHash, null);
  });
});

describe("security", () => {
  test("24. one account's code cannot verify another, and no user ID is accepted", async () => {
    const a = uniqueEmail();
    const b = uniqueEmail();
    await register(a);
    await register(b);
    const codeA = latestCodeFor(a);
    const userA = await userByEmail(a);
    const userB = await userByEmail(b);

    if (codeA !== latestCodeFor(b)) {
      assert.equal((await verify(b, codeA)).status, 400);
    }
    // The same code, hashed for B, would not match: hashes are bound to the user.
    assert.notEqual(hashCode(userA.id, codeA), hashCode(userB.id, codeA));

    for (const extra of [{ userId: userB.id }, { id: userB.id }, { emailVerified: true }]) {
      const res = await call("POST", "/api/auth/verify-email", { body: { email: a, code: codeA, ...extra } });
      assert.equal(res.status, 400, res.raw);
    }
    assert.equal((await userByEmail(b)).emailVerified, false);
    assert.equal((await verify(a, codeA)).status, 200);
    assert.equal((await userByEmail(b)).emailVerified, false);
  });

  describe("without a working mailer", () => {
    const SMTP_KEYS = ["SMTP_HOST", "SMTP_PORT", "SMTP_SECURE", "SMTP_USER", "SMTP_PASSWORD", "SMTP_FROM"];
    const SMTP_PASSWORD = `smtp-secret-${randomUUID()}`;
    let savedEnv: Record<string, string | undefined>;

    before(() => {
      savedEnv = Object.fromEntries(SMTP_KEYS.map((k) => [k, process.env[k]]));
      setEmailSender(null);
    });

    after(() => {
      for (const [k, v] of Object.entries(savedEnv)) {
        if (v === undefined) delete process.env[k];
        else process.env[k] = v;
      }
      setEmailSender(async (message) => {
        sentEmails.push(message);
      });
    });

    test("registration answers 503 and creates nothing when SMTP is not configured", async () => {
      for (const k of SMTP_KEYS) delete process.env[k];
      process.env.SMTP_PASSWORD = SMTP_PASSWORD;
      const email = uniqueEmail();

      const res = await register(email);
      assert.equal(res.status, 503, res.raw);
      assert.equal(res.json.code, "EMAIL_UNAVAILABLE");
      assert.equal(await prisma.user.count({ where: { email } }), 0);
      assert.equal((await resend(email)).status, 503);
    });

    test("23. a failed delivery answers 503, keeps no usable code, and never logs the SMTP password", async () => {
      // A port with nothing listening: the connection is refused at once.
      const closed = createServer();
      await new Promise<void>((resolve) => closed.listen(0, "127.0.0.1", resolve));
      const port = (closed.address() as AddressInfo).port;
      await new Promise<void>((resolve) => closed.close(() => resolve()));

      Object.assign(process.env, {
        SMTP_HOST: "127.0.0.1",
        SMTP_PORT: String(port),
        SMTP_SECURE: "false",
        SMTP_USER: "child-assist@test.local",
        SMTP_PASSWORD,
        SMTP_FROM: "Child Assist <child-assist@test.local>",
      });
      const email = uniqueEmail();
      const res = await register(email);
      assert.equal(res.status, 503, res.raw);
      assert.equal(res.json.code, "EMAIL_DELIVERY_FAILED");

      const user = await userByEmail(email);
      assert.equal(user.emailVerified, false);
      assert.equal((await codesOf(user.id)).length, 0);

      for (const text of [...logLines, ...responses]) {
        assert.ok(!text.includes(SMTP_PASSWORD), `SMTP password leaked: ${text}`);
      }
      assert.ok(logLines.some((l) => l.startsWith("Email delivery failed")), "the failure is logged");
    });
  });
});
