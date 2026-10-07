import { createHash, createHmac, hkdfSync, randomBytes, timingSafeEqual } from "node:crypto";
import bcrypt from "bcryptjs";
import { env } from "../../config/env";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import { assertEmailConfigured, googleAccountResetEmail, passwordResetEmail, sendEmail } from "../../lib/email";
import { generateCode } from "./email-verification.service";
import { BCRYPT_ROUNDS } from "./auth.service";
import { notifyInBackground } from "../notifications/notification.service";
import { templates } from "../notifications/notification.types";

// "Forgot password". Separate from email verification throughout: its own table, its own HMAC key
// (so a code issued for one purpose can never match the other) and its own errors.
//
// 1. forgot-password / resend-reset-code: a password account is emailed a 6-digit code. The answer
//    is the same for every email, and the work happens after responding, so neither the body nor
//    the timing reveals whether an account exists.
// 2. verify-reset-code: a correct code returns a reset token. The password is not changed yet.
// 3. reset-password: the token sets the new password once. It is not a JWT and opens nothing else.

export const RESET_CODE_TTL_MINUTES = 10;
export const RESET_MAX_ATTEMPTS = 5;
export const RESET_RESEND_COOLDOWN_MS = 60_000;
export const RESET_MAX_CODES_PER_HOUR = 5;
export const RESET_MAX_CODES_PER_DAY = 10;
export const RESET_TOKEN_TTL_MINUTES = 10;

const HOUR_MS = 60 * 60_000;
const DAY_MS = 24 * HOUR_MS;

// A Google-only account is told by email to use Google; at most this often per address.
const GOOGLE_NOTICE_COOLDOWN_MS = 10 * 60_000;

const codeKey = Buffer.from(hkdfSync("sha256", env.jwtSecret, "", "child-assist/password-reset-code", 32));

export const INVALID_RESET_CODE =
  "This code is invalid or has expired. Check your latest email or request a new code.";
export const INVALID_RESET_TOKEN = "Your password reset session has expired. Please request a new code.";

function invalidCode(): HttpError {
  return new HttpError(400, INVALID_RESET_CODE, "INVALID_RESET_CODE");
}

function invalidToken(): HttpError {
  return new HttpError(400, INVALID_RESET_TOKEN, "INVALID_RESET_TOKEN");
}

/** Bound to the user, so a code (or its hash) for one account is useless for another. */
export function hashResetCode(userId: string, code: string): string {
  return createHmac("sha256", codeKey).update(`${userId}:${code}`).digest("hex");
}

function codeMatches(userId: string, code: string, codeHash: string): boolean {
  const expected = Buffer.from(codeHash, "hex");
  const actual = Buffer.from(hashResetCode(userId, code), "hex");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/** Tokens carry 256 random bits, so a plain SHA-256 cannot be reversed; it lets us look them up. */
export function hashResetToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

// Emails go out after the response is sent, so slow SMTP does not reveal that an account exists.
const inflight = new Set<Promise<void>>();

function inBackground(work: () => Promise<unknown>): void {
  const task: Promise<void> = work()
    .then(() => undefined)
    .catch((err: unknown) => {
      // Delivery failures were already logged, without details, by the email service.
      if (err instanceof HttpError) return;
      const e = err instanceof Error ? err : new Error(String(err));
      console.error(`Password reset request failed: ${e.name}: ${e.message}`);
    })
    .finally(() => inflight.delete(task));
  inflight.add(task);
}

/** Resolves once every queued reset email has been handled. For tests and shutdown. */
export async function settlePasswordResetEmails(): Promise<void> {
  while (inflight.size > 0) await Promise.all([...inflight]);
}

/**
 * Handles forgot-password and resend-reset-code. Always returns normally (the caller answers the
 * same generic message), except a 503 when email is not configured, which says nothing about the
 * account. A password account gets a code, subject to the cooldown and caps; a Google-only account
 * is told by email to use Google and never gets a code or a password; anything else gets nothing.
 */
export async function requestPasswordReset(email: string): Promise<void> {
  assertEmailConfigured();
  const user = await prisma.user.findUnique({
    where: { email },
    select: { id: true, email: true, passwordHash: true, googleSubject: true },
  });
  if (!user) return;
  if (user.passwordHash) {
    inBackground(() => issueResetCode(user));
  } else if (user.googleSubject) {
    inBackground(() => notifyGoogleAccount(user.email));
  }
}

/**
 * Emails a fresh code, invalidating every earlier one (and any reset token from them). Returns
 * false, changing nothing, if the account has no password or a rate limit applies. Throws a 503
 * HttpError if the email could not be sent; the new code is then removed.
 */
export async function issueResetCode(user: { id: string; email: string }): Promise<boolean> {
  const code = generateCode();
  const now = new Date();

  const created = await prisma.$transaction(async (tx) => {
    // Locks the user row so concurrent requests for one account cannot both pass the limits.
    const [row] = await tx.$queryRaw<{ password_hash: string | null }[]>`
      SELECT password_hash FROM users WHERE id = ${user.id}::uuid FOR UPDATE`;
    if (!row?.password_hash) return null;

    const recent = await tx.passwordResetCode.findMany({
      where: { userId: user.id, createdAt: { gt: new Date(now.getTime() - DAY_MS) } },
      select: { createdAt: true },
      orderBy: { createdAt: "desc" },
    });
    const lastHour = recent.filter((c) => c.createdAt.getTime() > now.getTime() - HOUR_MS).length;
    if (
      (recent[0] && now.getTime() - recent[0].createdAt.getTime() < RESET_RESEND_COOLDOWN_MS) ||
      lastHour >= RESET_MAX_CODES_PER_HOUR ||
      recent.length >= RESET_MAX_CODES_PER_DAY
    ) {
      return null;
    }

    // The newest code replaces every earlier one.
    await tx.passwordResetCode.updateMany({
      where: { userId: user.id, consumedAt: null },
      data: { consumedAt: now },
    });
    return tx.passwordResetCode.create({
      data: {
        userId: user.id,
        codeHash: hashResetCode(user.id, code),
        expiresAt: new Date(now.getTime() + RESET_CODE_TTL_MINUTES * 60_000),
        createdAt: now,
      },
      select: { id: true },
    });
  });
  if (!created) return false;

  try {
    await sendEmail(passwordResetEmail(user.email, code, RESET_CODE_TTL_MINUTES));
  } catch (err) {
    // Nobody received this code: drop it so it does not count against the limits.
    await prisma.passwordResetCode.deleteMany({ where: { id: created.id } });
    throw err;
  }
  return true;
}

const googleNoticeSentAt = new Map<string, number>();

async function notifyGoogleAccount(email: string): Promise<void> {
  const now = Date.now();
  for (const [key, at] of googleNoticeSentAt) {
    if (now - at >= GOOGLE_NOTICE_COOLDOWN_MS) googleNoticeSentAt.delete(key);
  }
  if (googleNoticeSentAt.has(email)) return;
  googleNoticeSentAt.set(email, now);
  await sendEmail(googleAccountResetEmail(email));
}

/**
 * Checks a code against the account's latest active one. On a match, marks it verified and returns
 * a new reset token; the password is not changed. Every failure is the same 400.
 */
export async function verifyResetCode(email: string, code: string): Promise<string> {
  const user = await prisma.user.findUnique({ where: { email }, select: { id: true, passwordHash: true } });
  if (!user?.passwordHash) throw invalidCode();

  const now = new Date();
  const active = await prisma.passwordResetCode.findFirst({
    where: {
      userId: user.id,
      consumedAt: null,
      verifiedAt: null,
      expiresAt: { gt: now },
      attempts: { lt: RESET_MAX_ATTEMPTS },
    },
    orderBy: { createdAt: "desc" },
    select: { id: true, codeHash: true },
  });
  if (!active) throw invalidCode();

  // Count the attempt before comparing, atomically, so parallel guesses cannot exceed the limit.
  // After the fifth wrong attempt the code no longer matches the query above: it is dead.
  const claimed = await prisma.passwordResetCode.updateMany({
    where: { id: active.id, consumedAt: null, verifiedAt: null, attempts: { lt: RESET_MAX_ATTEMPTS } },
    data: { attempts: { increment: 1 } },
  });
  if (claimed.count === 0 || !codeMatches(user.id, code, active.codeHash)) throw invalidCode();

  const resetToken = randomBytes(32).toString("base64url");
  // Fails if a newer code replaced this one in the meantime, or it was already verified.
  const marked = await prisma.passwordResetCode.updateMany({
    where: { id: active.id, consumedAt: null, verifiedAt: null },
    data: {
      verifiedAt: now,
      resetTokenHash: hashResetToken(resetToken),
      resetTokenExpiresAt: new Date(now.getTime() + RESET_TOKEN_TTL_MINUTES * 60_000),
    },
  });
  if (marked.count === 0) throw invalidCode();
  return resetToken;
}

/**
 * Sets a new password with a token from verifyResetCode, once. Spends every outstanding reset code
 * for the account. Never signs in. Accounts without a password (Google-only) are never given one.
 */
export async function resetPassword(resetToken: string, newPassword: string): Promise<void> {
  // Hashed before the lookup so a bad token costs the same time as a good one.
  const passwordHash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
  const now = new Date();

  const userId = await prisma.$transaction(async (tx) => {
    const reset = await tx.passwordResetCode.findUnique({
      where: { resetTokenHash: hashResetToken(resetToken) },
      select: { id: true, userId: true, consumedAt: true, resetTokenExpiresAt: true },
    });
    if (!reset || reset.consumedAt || !reset.resetTokenExpiresAt || reset.resetTokenExpiresAt <= now) {
      throw invalidToken();
    }

    const [user] = await tx.$queryRaw<{ password_hash: string | null }[]>`
      SELECT password_hash FROM users WHERE id = ${reset.userId}::uuid FOR UPDATE`;
    if (!user?.password_hash) throw invalidToken();

    // Re-checked under the lock: a concurrent reset or a newer code may have spent it.
    const spent = await tx.passwordResetCode.updateMany({
      where: { id: reset.id, consumedAt: null },
      data: { consumedAt: now },
    });
    if (spent.count === 0) throw invalidToken();
    await tx.passwordResetCode.updateMany({
      where: { userId: reset.userId, consumedAt: null },
      data: { consumedAt: now },
    });
    await tx.user.update({ where: { id: reset.userId }, data: { passwordHash } });
    return reset.userId;
  });
  // Security alert to the account's signed-in phones; never contains the code or the token.
  notifyInBackground(userId, templates.passwordReset());
}
