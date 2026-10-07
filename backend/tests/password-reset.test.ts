// Integration tests for "Forgot password": forgot-password, resend-reset-code, verify-reset-code
// and reset-password. Runs the real app against the configured PostgreSQL database (DATABASE_URL).
// Email is captured in memory (tests/support/auth.ts); nothing is sent.
// Run with: npm test
import "dotenv/config";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, test } from "node:test";
import bcrypt from "bcryptjs";
import { createApp } from "../src/app";
import { setEmailSender } from "../src/lib/email";
import { HttpError } from "../src/lib/http-error";
import { verifyAccessToken } from "../src/lib/jwt";
import { prisma } from "../src/lib/prisma";
import { resetRateLimits } from "../src/middleware/rate-limit.middleware";
import { hashCode } from "../src/modules/auth/email-verification.service";
import {
  hashResetCode,
  hashResetToken,
  INVALID_RESET_CODE,
  INVALID_RESET_TOKEN,
  settlePasswordResetEmails,
} from "../src/modules/auth/password-reset.service";
import { emailsTo, latestCodeFor, registerVerifiedUser, sentEmails, TEST_PASSWORD } from "./support/auth";

let server: Server;
let baseUrl: string;
const createdEmails: string[] = [];
const responses: string[] = [];
const logLines: string[] = [];
const passwordsUsed = new Set<string>([TEST_PASSWORD]);

// Everything the app logs while these tests run, to prove codes and passwords never appear.
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
  const email = `reset-${randomUUID()}@test.local`;
  createdEmails.push(email);
  return email;
}

const GENERIC = { message: "If an account exists for this email, a password reset code has been sent." };
const RESET_SUBJECT = "Reset your Child Assist password";
const GOOGLE_SUBJECT = "Your Child Assist account uses Google Sign-In";

// Reset emails are sent after the response, so wait for them before looking at the inbox.
async function forgot(email: string) {
  const res = await call("POST", "/api/auth/forgot-password", { body: { email } });
  await settlePasswordResetEmails();
  return res;
}
async function resendReset(email: string) {
  const res = await call("POST", "/api/auth/resend-reset-code", { body: { email } });
  await settlePasswordResetEmails();
  return res;
}
const verifyReset = (email: string, code: string) =>
  call("POST", "/api/auth/verify-reset-code", { body: { email, code } });
function resetPassword(resetToken: string, newPassword: string, confirmPassword?: string) {
  if (newPassword.length >= 8) passwordsUsed.add(newPassword);
  return call("POST", "/api/auth/reset-password", { body: { resetToken, newPassword, confirmPassword } });
}
const login = (email: string, password = TEST_PASSWORD) =>
  call("POST", "/api/auth/login", { body: { email, password } });

const resetEmailsTo = (email: string) => emailsTo(email).filter((m) => m.subject === RESET_SUBJECT);

/** The code in the most recent password reset email to [email]. */
function latestResetCode(email: string): string {
  const message = resetEmailsTo(email).at(-1);
  assert.ok(message, `no reset email was sent to ${email}`);
  const code = message.text.match(/^(\d{6})$/m)?.[1];
  assert.ok(code, "the email has no 6-digit code");
  return code;
}

const userByEmail = (email: string) => prisma.user.findUniqueOrThrow({ where: { email } });
const resetCodesOf = (userId: string) =>
  prisma.passwordResetCode.findMany({ where: { userId }, orderBy: { createdAt: "asc" } });

/** Moves the user's reset codes into the past, as if [seconds] had passed since they were sent. */
async function age(userId: string, seconds: number): Promise<void> {
  await prisma.$executeRaw`
    UPDATE password_reset_codes SET created_at = created_at - make_interval(secs => ${seconds})
    WHERE user_id = ${userId}::uuid`;
}

async function googleOnlyUser(): Promise<string> {
  const email = uniqueEmail();
  await prisma.user.create({
    data: { name: "G", email, googleSubject: `sub-${randomUUID()}`, emailVerified: true },
  });
  return email;
}

/** A verified password account with a reset code just emailed to it. */
async function userWithResetCode(): Promise<{ email: string; id: string; code: string }> {
  const email = uniqueEmail();
  const { id } = await registerVerifiedUser(call, "Mansi", email);
  assert.equal((await forgot(email)).status, 200);
  return { email, id, code: latestResetCode(email) };
}

/** A verified password account holding a reset token. */
async function userWithResetToken(): Promise<{ email: string; id: string; resetToken: string }> {
  const { email, id, code } = await userWithResetCode();
  const res = await verifyReset(email, code);
  assert.equal(res.status, 200, res.raw);
  return { email, id, resetToken: res.json.resetToken };
}

const wrong = (code: string) => (code === "000000" ? "111111" : "000000");
const containsCode = (text: string, code: string) => new RegExp(`(^|[^0-9A-Za-z])${code}([^0-9A-Za-z]|$)`).test(text);

before(async () => {
  server = createApp().listen(0);
  await new Promise<void>((resolve) => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

// Every test starts with fresh per-IP limits; one test exercises them on purpose.
beforeEach(() => resetRateLimits());

after(async () => {
  await settlePasswordResetEmails();
  // 28-30. No emailed code, and no password, ever shows up in a response or a log line.
  const codes = sentEmails.map((m) => m.text.match(/^(\d{6})$/m)?.[1]).filter((c): c is string => !!c);
  assert.ok(codes.length > 10, "the suite should have issued codes");
  for (const code of codes) {
    for (const raw of responses) assert.ok(!containsCode(raw, code), `a response leaked a code: ${raw}`);
    for (const line of logLines) assert.ok(!containsCode(line, code), `a log line leaked a code: ${line}`);
  }
  for (const password of passwordsUsed) {
    for (const text of [...responses, ...logLines]) {
      assert.ok(!text.includes(password), `a response or log line contains a password: ${text}`);
    }
  }
  for (const method of consoleMethods) console[method] = originalConsole[method];

  await prisma.user.deleteMany({ where: { email: { in: createdEmails } } });
  await prisma.$disconnect();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("POST /api/auth/forgot-password", () => {
  test("1, 8, 9. a password account is emailed a fresh 6-digit code, stored only as an HMAC", async () => {
    const email = uniqueEmail();
    const { id } = await registerVerifiedUser(call, "Mansi", email);

    const res = await forgot(email);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json, GENERIC);

    const mails = resetEmailsTo(email);
    assert.equal(mails.length, 1);
    const [mail] = mails;
    const code = latestResetCode(email);
    assert.match(code, /^\d{6}$/);
    assert.ok(mail.html.includes(code));
    assert.match(mail.text, /^Password Reset$/m);
    assert.match(mail.text, /We received a request to reset your Child Assist password\./);
    assert.match(mail.text, /This code expires in 10 minutes\./);
    assert.match(mail.text, /If you did not request this, you can safely ignore this email\./);
    const user = await userByEmail(email);
    for (const secret of [TEST_PASSWORD, user.id, user.passwordHash!]) {
      assert.ok(!mail.text.includes(secret) && !mail.html.includes(secret), `the email contains ${secret}`);
    }

    const codes = await resetCodesOf(id);
    assert.equal(codes.length, 1);
    assert.equal(codes[0].codeHash, hashResetCode(id, code));
    assert.match(codes[0].codeHash, /^[0-9a-f]{64}$/);
    assert.ok(!containsCode(JSON.stringify(codes), code), "the plain code is stored");
    assert.equal(codes[0].attempts, 0);
    assert.equal(codes[0].consumedAt, null);
    assert.equal(codes[0].verifiedAt, null);
    assert.equal(codes[0].resetTokenHash, null);
    assert.equal(codes[0].expiresAt.getTime() - codes[0].createdAt.getTime(), 10 * 60_000);

    // Nothing about the password or email verification changed.
    assert.equal((await userByEmail(email)).passwordHash, user.passwordHash);
    assert.equal(await prisma.emailVerificationCode.count({ where: { userId: id, consumedAt: null } }), 0);
  });

  test("2, 31. an unknown email gets the identical answer, and nothing is created or sent", async () => {
    const email = uniqueEmail();
    const sentBefore = sentEmails.length;
    const res = await forgot(email);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json, GENERIC);
    assert.equal(sentEmails.length, sentBefore);
    assert.equal(await prisma.user.count({ where: { email } }), 0);
  });

  test("3, 32. a Google-only account gets the same answer, no code and no password, only a 'use Google' email", async () => {
    const email = await googleOnlyUser();
    const user = await userByEmail(email);

    const res = await forgot(email);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json, GENERIC);
    assert.equal((await resetCodesOf(user.id)).length, 0);
    assert.equal(resetEmailsTo(email).length, 0);

    const notices = emailsTo(email).filter((m) => m.subject === GOOGLE_SUBJECT);
    assert.equal(notices.length, 1);
    assert.match(notices[0].text, /Continue with Google/);
    assert.ok(!/\b\d{6}\b/.test(notices[0].text), "the notice carries no code");

    // Repeats within the cooldown do not send it again.
    await forgot(email);
    await resendReset(email);
    assert.equal(emailsTo(email).filter((m) => m.subject === GOOGLE_SUBJECT).length, 1);

    const after = await userByEmail(email);
    assert.equal(after.passwordHash, null);
    assert.equal(after.googleSubject, user.googleSubject);
  });

  test("4. rejects an invalid email or extra fields", async () => {
    const email = uniqueEmail();
    await registerVerifiedUser(call, "Mansi", email);
    const user = await userByEmail(email);
    for (const body of [{ email: "not-an-email" }, {}, { email: "" }, { email, userId: user.id }, "x"]) {
      const res = await call("POST", "/api/auth/forgot-password", { body });
      assert.equal(res.status, 400, res.raw);
    }
    await settlePasswordResetEmails();
    assert.equal(resetEmailsTo(email).length, 0);
  });

  test("5. rate limits requests per client, whatever the email", async () => {
    for (let i = 0; i < 10; i++) {
      assert.equal((await forgot(uniqueEmail())).status, 200);
    }
    const limited = await forgot(uniqueEmail());
    assert.equal(limited.status, 429, limited.raw);
    assert.equal(limited.json.code, "RATE_LIMITED");
    // Resending shares the same budget.
    assert.equal((await resendReset(uniqueEmail())).status, 429);
  });

  test("6, 10. the 60-second cooldown holds back new codes; a newer code invalidates the older", async () => {
    const { email, id, code: first } = await userWithResetCode();

    // Within the cooldown: the same answer, but nothing new is sent.
    assert.deepEqual((await forgot(email)).json, GENERIC);
    assert.deepEqual((await resendReset(email)).json, GENERIC);
    assert.equal(resetEmailsTo(email).length, 1);

    await age(id, 61);
    const res = await resendReset(email);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json, GENERIC);
    assert.equal(resetEmailsTo(email).length, 2);
    const second = latestResetCode(email);

    const codes = await resetCodesOf(id);
    assert.equal(codes.length, 2);
    assert.ok(codes[0].consumedAt, "the old code is invalidated");
    assert.equal(codes[1].consumedAt, null);

    if (first !== second) assert.equal((await verifyReset(email, first)).status, 400);
    assert.equal((await verifyReset(email, second)).status, 200);
  });

  test("caps codes at five per hour per account", async () => {
    const { email, id } = await userWithResetCode();
    for (let i = 0; i < 4; i++) {
      await age(id, 61);
      await resendReset(email);
    }
    assert.equal(resetEmailsTo(email).length, 5);
    await age(id, 61);
    await resendReset(email);
    assert.equal(resetEmailsTo(email).length, 5, "the sixth code within an hour is not sent");
  });

  describe("7. when email cannot be sent", () => {
    after(() => {
      setEmailSender(async (message) => {
        sentEmails.push(message);
      });
    });

    test("a delivery failure still answers generically and keeps no usable code", async () => {
      const email = uniqueEmail();
      const { id } = await registerVerifiedUser(call, "Mansi", email);
      setEmailSender(async () => {
        console.error("Email delivery failed (code=ECONNREFUSED, smtp=-)");
        throw new HttpError(503, "We couldn't send the verification email.", "EMAIL_DELIVERY_FAILED");
      });

      const res = await forgot(email);
      assert.equal(res.status, 200, res.raw);
      assert.deepEqual(res.json, GENERIC);
      assert.equal((await resetCodesOf(id)).length, 0);
    });

    test("an unconfigured mailer answers 503 for every email alike", async () => {
      setEmailSender(null);
      const saved = { host: process.env.SMTP_HOST, from: process.env.SMTP_FROM };
      delete process.env.SMTP_HOST;
      delete process.env.SMTP_FROM;
      try {
        const known = uniqueEmail();
        await prisma.user.create({ data: { name: "K", email: known, passwordHash: "x", emailVerified: true } });
        for (const email of [known, uniqueEmail()]) {
          const res = await forgot(email);
          assert.equal(res.status, 503, res.raw);
          assert.equal(res.json.code, "EMAIL_UNAVAILABLE");
        }
      } finally {
        if (saved.host !== undefined) process.env.SMTP_HOST = saved.host;
        if (saved.from !== undefined) process.env.SMTP_FROM = saved.from;
      }
    });
  });
});

describe("POST /api/auth/verify-reset-code", () => {
  test("11, 17. the right code returns a reset token, not a session, and leaves the password alone", async () => {
    const { email, id, code } = await userWithResetCode();
    const before = await userByEmail(email);

    const res = await verifyReset(email, code);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(Object.keys(res.json).sort(), ["expiresInSeconds", "message", "resetToken"]);
    assert.match(res.json.resetToken, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(res.json.expiresInSeconds, 600);
    assert.throws(() => verifyAccessToken(res.json.resetToken), "the reset token is not a JWT");

    const [stored] = await resetCodesOf(id);
    assert.ok(stored.verifiedAt);
    assert.equal(stored.consumedAt, null);
    assert.equal(stored.resetTokenHash, hashResetToken(res.json.resetToken));
    assert.ok(!JSON.stringify(stored).includes(res.json.resetToken), "the plain token is stored");
    assert.equal(stored.resetTokenExpiresAt!.getTime() - stored.verifiedAt!.getTime(), 10 * 60_000);

    assert.equal((await userByEmail(email)).passwordHash, before.passwordHash);
    assert.equal((await login(email)).status, 200, "the old password still works until reset");
  });

  test("12. a wrong code fails, counts an attempt, and the right one still works", async () => {
    const { email, id, code } = await userWithResetCode();
    const res = await verifyReset(email, wrong(code));
    assert.equal(res.status, 400, res.raw);
    assert.deepEqual(res.json, { message: INVALID_RESET_CODE, code: "INVALID_RESET_CODE" });
    assert.equal((await resetCodesOf(id))[0].attempts, 1);
    assert.equal((await verifyReset(email, code)).status, 200);
  });

  test("13. an expired code fails even when correct", async () => {
    const { email, id, code } = await userWithResetCode();
    await prisma.passwordResetCode.updateMany({ where: { userId: id }, data: { expiresAt: new Date(Date.now() - 1000) } });
    const res = await verifyReset(email, code);
    assert.equal(res.status, 400, res.raw);
    assert.equal(res.json.code, "INVALID_RESET_CODE");
  });

  test("14. a code works once", async () => {
    const { email, code } = await userWithResetCode();
    assert.equal((await verifyReset(email, code)).status, 200);
    const again = await verifyReset(email, code);
    assert.equal(again.status, 400, again.raw);
    assert.equal(again.json.code, "INVALID_RESET_CODE");
  });

  test("15. five wrong attempts kill the code; four wrong then right still works", async () => {
    const { email, code } = await userWithResetCode();
    for (let i = 0; i < 5; i++) assert.equal((await verifyReset(email, wrong(code))).status, 400);
    assert.equal((await verifyReset(email, code)).status, 400);

    const other = await userWithResetCode();
    for (let i = 0; i < 4; i++) assert.equal((await verifyReset(other.email, wrong(other.code))).status, 400);
    assert.equal((await verifyReset(other.email, other.code)).status, 200);
  });

  test("parallel guesses cannot exceed the attempt limit", async () => {
    const { email, id, code } = await userWithResetCode();
    const results = await Promise.all(Array.from({ length: 12 }, () => verifyReset(email, wrong(code))));
    assert.ok(results.every((r) => r.status === 400));
    assert.equal((await resetCodesOf(id))[0].attempts, 5);
    assert.equal((await verifyReset(email, code)).status, 400);
  });

  test("16. only six digits are accepted, and malformed codes do not count as attempts", async () => {
    const { email, id } = await userWithResetCode();
    for (const code of ["12345", "1234567", "abcdef", "12 456", ""]) {
      assert.equal((await verifyReset(email, code)).status, 400, code);
    }
    assert.equal((await resetCodesOf(id))[0].attempts, 0);
  });

  test("unknown and Google-only accounts get the same failure", async () => {
    for (const email of [uniqueEmail(), await googleOnlyUser()]) {
      const res = await verifyReset(email, "123456");
      assert.equal(res.status, 400, res.raw);
      assert.deepEqual(res.json, { message: INVALID_RESET_CODE, code: "INVALID_RESET_CODE" });
    }
  });
});

describe("POST /api/auth/reset-password", () => {
  test("18, 23, 26, 27. a valid token sets the new password; the old one stops working; no session is issued", async () => {
    const { email, id, resetToken } = await userWithResetToken();
    const newPassword = "brand-new-pass-1";

    const res = await resetPassword(resetToken, newPassword, newPassword);
    assert.equal(res.status, 200, res.raw);
    assert.deepEqual(res.json, { message: "Password reset successfully." });

    const user = await userByEmail(email);
    assert.ok(await bcrypt.compare(newPassword, user.passwordHash!), "the new password is bcrypt-hashed");
    assert.match(user.passwordHash!, /^\$2[aby]\$12\$/);
    assert.equal(user.id, id);

    const old = await login(email, TEST_PASSWORD);
    assert.equal(old.status, 401, old.raw);
    const fresh = await login(email, newPassword);
    assert.equal(fresh.status, 200, fresh.raw);
    assert.equal(fresh.json.user.id, id);
  });

  test("24, 25. afterwards the token, the code and every other reset code are spent", async () => {
    const { email, id, code } = await userWithResetCode();
    const { json } = await verifyReset(email, code);
    assert.equal((await resetPassword(json.resetToken, "first-new-pass")).status, 200);

    assert.ok((await resetCodesOf(id)).every((c) => c.consumedAt), "every reset code is consumed");
    const reuse = await resetPassword(json.resetToken, "second-new-pass");
    assert.equal(reuse.status, 400, reuse.raw);
    assert.deepEqual(reuse.json, { message: INVALID_RESET_TOKEN, code: "INVALID_RESET_TOKEN" });
    assert.equal((await verifyReset(email, code)).status, 400);
    assert.equal((await login(email, "first-new-pass")).status, 200);
  });

  test("19. an expired token is refused", async () => {
    const { email, id, resetToken } = await userWithResetToken();
    await prisma.passwordResetCode.updateMany({
      where: { userId: id },
      data: { resetTokenExpiresAt: new Date(Date.now() - 1000) },
    });
    const res = await resetPassword(resetToken, "never-applied-1");
    assert.equal(res.status, 400, res.raw);
    assert.equal(res.json.code, "INVALID_RESET_TOKEN");
    assert.equal((await login(email)).status, 200);
  });

  test("20. an unknown or malformed token is refused", async () => {
    const unknown = await resetPassword(randomBytes(32).toString("base64url"), "never-applied-2");
    assert.equal(unknown.status, 400, unknown.raw);
    assert.equal(unknown.json.code, "INVALID_RESET_TOKEN");
    for (const token of ["", "short", "x".repeat(44), "a".repeat(42) + "!"]) {
      assert.equal((await resetPassword(token, "never-applied-3")).status, 400, token);
    }
  });

  test("a newer code invalidates a token issued from an older one", async () => {
    const { email, id, resetToken } = await userWithResetToken();
    await age(id, 61);
    await resendReset(email);
    const res = await resetPassword(resetToken, "never-applied-4");
    assert.equal(res.status, 400, res.raw);
    assert.equal((await login(email)).status, 200);
  });

  test("21. a weak password is refused with the registration rules, and the token stays usable", async () => {
    const { email, resetToken } = await userWithResetToken();
    for (const weak of ["short", "", "x".repeat(73)]) {
      const res = await resetPassword(resetToken, weak);
      assert.equal(res.status, 400, res.raw);
      assert.equal(res.json.message, "Validation failed");
      assert.equal(res.json.errors[0].field, "newPassword");
    }
    assert.equal((await login(email)).status, 200, "the password is unchanged");
    assert.equal((await resetPassword(resetToken, "strong-enough-1")).status, 200);
  });

  test("22. a confirmation that does not match is refused", async () => {
    const { email, resetToken } = await userWithResetToken();
    const res = await resetPassword(resetToken, "matching-pass-1", "different-pass-1");
    assert.equal(res.status, 400, res.raw);
    assert.equal(res.json.errors[0].field, "confirmPassword");
    assert.equal((await login(email)).status, 200);
  });

  test("an unverified account can reset, but still has to verify its email to log in", async () => {
    const email = uniqueEmail();
    await call("POST", "/api/auth/register", { body: { name: "New", email, password: TEST_PASSWORD } });
    await forgot(email);
    const { json } = await verifyReset(email, latestResetCode(email));
    assert.equal((await resetPassword(json.resetToken, "unverified-new-1")).status, 200);

    const res = await login(email, "unverified-new-1");
    assert.equal(res.status, 403, res.raw);
    assert.equal(res.json.code, "EMAIL_NOT_VERIFIED");
    assert.equal((await userByEmail(email)).emailVerified, false);
  });
});

describe("security", () => {
  test("16 (separation). an email verification code never resets a password, and a reset code never verifies an email", async () => {
    const email = uniqueEmail();
    await call("POST", "/api/auth/register", { body: { name: "New", email, password: TEST_PASSWORD } });
    const user = await userByEmail(email);
    const verificationCode = latestCodeFor(email);
    await forgot(email);
    const resetCode = latestResetCode(email);

    // The two purposes use different keys, so even the same digits hash differently.
    assert.notEqual(hashResetCode(user.id, resetCode), hashCode(user.id, resetCode));

    if (verificationCode !== resetCode) {
      assert.equal((await verifyReset(email, verificationCode)).status, 400);
      const verify = await call("POST", "/api/auth/verify-email", { body: { email, code: resetCode } });
      assert.equal(verify.status, 400, verify.raw);
      assert.equal((await userByEmail(email)).emailVerified, false);
    }
  });

  test("32. a Google-only account can never be given a password, even holding a reset token", async () => {
    const email = await googleOnlyUser();
    const user = await userByEmail(email);
    // A reset row that should never exist, forged directly in the database.
    const resetToken = randomBytes(32).toString("base64url");
    await prisma.passwordResetCode.create({
      data: {
        userId: user.id,
        codeHash: hashResetCode(user.id, "123456"),
        expiresAt: new Date(Date.now() + 60_000),
        verifiedAt: new Date(),
        resetTokenHash: hashResetToken(resetToken),
        resetTokenExpiresAt: new Date(Date.now() + 60_000),
      },
    });

    const res = await resetPassword(resetToken, "google-pass-123");
    assert.equal(res.status, 400, res.raw);
    assert.equal((await userByEmail(email)).passwordHash, null);
    const google = await login(email, "google-pass-123");
    assert.equal(google.json.code, "USE_GOOGLE_SIGN_IN");
  });

  test("33. a reset token opens no protected API, and a login JWT is not a reset token", async () => {
    const { email, resetToken } = await userWithResetToken();
    for (const path of ["/api/auth/me", "/api/profile", "/api/permissions", "/api/location/history", "/api/chat/conversations"]) {
      const res = await call("GET", path, { token: resetToken });
      assert.equal(res.status, 401, `${path}: ${res.raw}`);
    }

    const { json } = await login(email);
    const res = await resetPassword(json.token, "jwt-as-token-1");
    assert.equal(res.status, 400, res.raw);
    assert.equal((await login(email)).status, 200);
  });

  test("the request body cannot name another account", async () => {
    const { email, resetToken } = await userWithResetToken();
    const other = uniqueEmail();
    const { id: otherId } = await registerVerifiedUser(call, "Other", other);
    for (const extra of [{ userId: otherId }, { email: other }]) {
      const res = await call("POST", "/api/auth/reset-password", {
        body: { resetToken, newPassword: "hijack-pass-12", ...extra },
      });
      assert.equal(res.status, 400, res.raw);
    }
    assert.equal((await login(other)).status, 200);
    assert.equal((await login(email)).status, 200);
  });
});
