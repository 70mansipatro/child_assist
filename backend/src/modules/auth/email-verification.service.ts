import { createHmac, hkdfSync, randomInt, timingSafeEqual } from "node:crypto";
import { env } from "../../config/env";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import { sendEmail, verificationEmail } from "../../lib/email";

export const CODE_TTL_MINUTES = 10;
export const MAX_ATTEMPTS = 5;
export const RESEND_COOLDOWN_MS = 60_000;
export const MAX_CODES_PER_HOUR = 5;
export const MAX_CODES_PER_DAY = 10;

const HOUR_MS = 60 * 60_000;
const DAY_MS = 24 * HOUR_MS;

// Codes are stored as an HMAC keyed from the server secret, not a plain hash: there are only a
// million 6-digit codes, so a plain hash from a leaked database would be trivial to reverse.
const codeKey = Buffer.from(hkdfSync("sha256", env.jwtSecret, "", "child-assist/email-verification-code", 32));

/** One message for every failure, so it never reveals whether the email has an account. */
export const INVALID_CODE = "This code is invalid or has expired. Check your latest email or request a new code.";

function invalidCode(): HttpError {
  return new HttpError(400, INVALID_CODE, "INVALID_VERIFICATION_CODE");
}

/** A uniformly random 6-digit code from the OS CSPRNG. */
export function generateCode(): string {
  return randomInt(0, 1_000_000).toString().padStart(6, "0");
}

/** Bound to the user, so a code (or its hash) for one account is useless for another. */
export function hashCode(userId: string, code: string): string {
  return createHmac("sha256", codeKey).update(`${userId}:${code}`).digest("hex");
}

function codeMatches(userId: string, code: string, codeHash: string): boolean {
  const expected = Buffer.from(codeHash, "hex");
  const actual = Buffer.from(hashCode(userId, code), "hex");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

export interface IssueOptions {
  /** Apply the resend cooldown and hourly/daily caps. Off only for a brand-new account's first code. */
  enforceLimits: boolean;
  /**
   * New name and password from a repeat registration of a still-unverified account. They replace
   * the old ones in the same step that invalidates the old codes, so whoever verifies always gets
   * the credentials submitted with the latest emailed code. This stops someone who registered
   * another person's address first from keeping their own password on it.
   */
  credentials?: { name: string; passwordHash: string };
}

/**
 * Emails a fresh code to an unverified account, invalidating any earlier code. Returns false,
 * changing nothing, if the account is already verified or a rate limit applies. Throws a 503
 * HttpError if the email could not be sent.
 */
export async function issueVerificationCode(
  user: { id: string; email: string },
  options: IssueOptions,
): Promise<boolean> {
  const code = generateCode();
  const now = new Date();

  const created = await prisma.$transaction(async (tx) => {
    // Locks the user row, so concurrent registrations, resends and verifications of one account
    // run one at a time and cannot both pass the rate limits.
    const [row] = await tx.$queryRaw<{ email_verified: boolean }[]>`
      SELECT email_verified FROM users WHERE id = ${user.id}::uuid FOR UPDATE`;
    if (!row || row.email_verified) return null;

    if (options.enforceLimits) {
      const recent = await tx.emailVerificationCode.findMany({
        where: { userId: user.id, createdAt: { gt: new Date(now.getTime() - DAY_MS) } },
        select: { createdAt: true },
        orderBy: { createdAt: "desc" },
      });
      const lastHour = recent.filter((c) => c.createdAt.getTime() > now.getTime() - HOUR_MS).length;
      if (
        (recent[0] && now.getTime() - recent[0].createdAt.getTime() < RESEND_COOLDOWN_MS) ||
        lastHour >= MAX_CODES_PER_HOUR ||
        recent.length >= MAX_CODES_PER_DAY
      ) {
        return null;
      }
    }

    if (options.credentials) {
      await tx.user.update({ where: { id: user.id }, data: options.credentials });
    }
    // The newest code replaces every earlier one.
    await tx.emailVerificationCode.updateMany({
      where: { userId: user.id, consumedAt: null },
      data: { consumedAt: now },
    });
    return tx.emailVerificationCode.create({
      data: {
        userId: user.id,
        codeHash: hashCode(user.id, code),
        expiresAt: new Date(now.getTime() + CODE_TTL_MINUTES * 60_000),
        createdAt: now,
      },
      select: { id: true },
    });
  });
  if (!created) return false;

  try {
    await sendEmail(verificationEmail(user.email, code, CODE_TTL_MINUTES));
  } catch (err) {
    // Nobody received this code: drop it so it does not count against the resend limits.
    await prisma.emailVerificationCode.deleteMany({ where: { id: created.id } });
    throw err;
  }
  return true;
}

/**
 * Like issueVerificationCode, for flows whose response must not depend on the outcome (it would
 * reveal whether the account exists). Delivery failures are logged by the email service.
 */
export async function issueVerificationCodeQuietly(
  user: { id: string; email: string },
  options: IssueOptions,
): Promise<void> {
  try {
    await issueVerificationCode(user, options);
  } catch (err) {
    if (!(err instanceof HttpError)) throw err;
  }
}

/**
 * Checks a code against the account's latest active one and, if it matches, marks the email
 * verified and spends every outstanding code. Every failure is the same 400.
 */
export async function verifyEmailCode(email: string, code: string): Promise<void> {
  const user = await prisma.user.findUnique({
    where: { email },
    select: { id: true, emailVerified: true, passwordHash: true },
  });
  if (!user || user.emailVerified || !user.passwordHash) throw invalidCode();

  const now = new Date();
  const active = await prisma.emailVerificationCode.findFirst({
    where: { userId: user.id, consumedAt: null, expiresAt: { gt: now }, attempts: { lt: MAX_ATTEMPTS } },
    orderBy: { createdAt: "desc" },
    select: { id: true, codeHash: true },
  });
  if (!active) throw invalidCode();

  // Count the attempt before comparing, atomically, so parallel guesses cannot exceed the limit.
  // After the fifth wrong attempt the code no longer matches the query above: it is dead.
  const claimed = await prisma.emailVerificationCode.updateMany({
    where: { id: active.id, consumedAt: null, attempts: { lt: MAX_ATTEMPTS } },
    data: { attempts: { increment: 1 } },
  });
  if (claimed.count === 0 || !codeMatches(user.id, code, active.codeHash)) throw invalidCode();

  await prisma.$transaction(async (tx) => {
    await tx.$queryRaw`SELECT id FROM users WHERE id = ${user.id}::uuid FOR UPDATE`;
    // A newer code (e.g. from a resend) may have replaced this one in the meantime.
    const spent = await tx.emailVerificationCode.updateMany({
      where: { id: active.id, consumedAt: null },
      data: { consumedAt: now },
    });
    if (spent.count === 0) throw invalidCode();
    await tx.emailVerificationCode.updateMany({ where: { userId: user.id, consumedAt: null }, data: { consumedAt: now } });
    await tx.user.update({ where: { id: user.id }, data: { emailVerified: true } });
  });
}
