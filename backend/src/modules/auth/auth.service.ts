import bcrypt from "bcryptjs";
import { Prisma } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import { signAccessToken } from "../../lib/jwt";
import { verifyGoogleIdToken } from "../../lib/google-token";
import { assertEmailConfigured } from "../../lib/email";
import { notifyInBackground } from "../notifications/notification.service";
import { templates } from "../notifications/notification.types";
import { issueVerificationCode, issueVerificationCodeQuietly, verifyEmailCode } from "./email-verification.service";
import type {
  GoogleLoginInput,
  LoginInput,
  RegisterInput,
  ResendVerificationInput,
  VerifyEmailInput,
} from "./auth.validation";

export const BCRYPT_ROUNDS = 12;

// The only user fields ever returned to clients. passwordHash is never part of this.
const safeUserSelect = { id: true, name: true, email: true } as const;

export type SafeUser = Prisma.UserGetPayload<{ select: typeof safeUserSelect }>;

export interface AuthResult {
  user: SafeUser;
  token: string;
}

// Compared against when the email is unknown, so login takes similar time either way
// and response timing does not reveal whether an email is registered.
const DUMMY_HASH = bcrypt.hashSync("timing-equalisation-placeholder", BCRYPT_ROUNDS);

/**
 * Creates an unverified password account and emails it a verification code. No session is
 * started: the user logs in after verifying. Returns the same way whether or not the email is
 * already registered, so registration cannot be used to discover accounts:
 * - a new email gets an account and a code;
 * - an existing unverified password account gets the new name/password and a fresh code
 *   (subject to the resend limits), and only takes effect once that code is verified;
 * - a verified or Google account is left untouched and nothing is sent.
 */
export async function register(input: RegisterInput): Promise<void> {
  // Refuse before creating anything if no code could be sent.
  assertEmailConfigured();

  // Hashed before the lookup so every branch pays the same bcrypt cost.
  const passwordHash = await bcrypt.hash(input.password, BCRYPT_ROUNDS);

  const existing = await prisma.user.findUnique({
    where: { email: input.email },
    select: { id: true, email: true, emailVerified: true, passwordHash: true },
  });
  if (existing) {
    if (!existing.emailVerified && existing.passwordHash) {
      await issueVerificationCodeQuietly(existing, {
        enforceLimits: true,
        credentials: { name: input.name, passwordHash },
      });
    }
    return;
  }

  let user: { id: string; email: string };
  try {
    user = await prisma.user.create({
      data: { name: input.name, email: input.email, passwordHash, emailVerified: false },
      select: { id: true, email: true },
    });
  } catch (err) {
    // A concurrent registration created it first; answer as for any existing account.
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") return;
    throw err;
  }
  await issueVerificationCode(user, { enforceLimits: false });
}

/** Marks the account verified if the code is right. See verifyEmailCode. */
export async function verifyEmail(input: VerifyEmailInput): Promise<void> {
  await verifyEmailCode(input.email, input.code);
}

/** Emails a new code if the account exists and still needs verifying; silent otherwise. */
export async function resendVerification(input: ResendVerificationInput): Promise<void> {
  assertEmailConfigured();
  const user = await prisma.user.findUnique({
    where: { email: input.email },
    select: { id: true, email: true, emailVerified: true, passwordHash: true },
  });
  if (user && !user.emailVerified && user.passwordHash) {
    await issueVerificationCodeQuietly(user, { enforceLimits: true });
  }
}

/** The right password for an account whose email is not verified yet: no session is issued. */
export interface VerificationRequired {
  requiresEmailVerification: true;
}

export async function login(input: LoginInput): Promise<AuthResult | VerificationRequired> {
  const user = await prisma.user.findUnique({
    where: { email: input.email },
    select: { ...safeUserSelect, passwordHash: true, emailVerified: true },
  });

  const passwordOk = await bcrypt.compare(input.password, user?.passwordHash ?? DUMMY_HASH);
  if (user && !user.passwordHash) {
    // A Google-only account has no password to check.
    throw new HttpError(
      401,
      "This account uses Google Sign-In. Please continue with Google.",
      "USE_GOOGLE_SIGN_IN",
    );
  }
  if (!user || !passwordOk) {
    throw new HttpError(401, "Invalid email or password");
  }

  if (!user.emailVerified) {
    // The password proves this is the account owner, so it is safe to say why and send a code
    // (unless one was sent moments ago; the rate limits apply).
    await issueVerificationCodeQuietly(user, { enforceLimits: true });
    return { requiresEmailVerification: true };
  }

  return signedIn({ id: user.id, name: user.name, email: user.email });
}

/**
 * Starts a session and tells the account's devices about it ("A new device signed in"). The alert
 * reaches phones that are already signed in; the phone signing in registers for pushes only
 * afterwards. It names no device, place or address, and never delays or fails the login.
 */
function signedIn(user: SafeUser): AuthResult {
  notifyInBackground(user.id, templates.newLogin());
  return { user, token: signAccessToken(user.id) };
}

const ACCOUNT_EXISTS = new HttpError(
  409,
  "An account already exists with this email. Please sign in with your password first, then use the account-linking option.",
  "ACCOUNT_EXISTS_WITH_PASSWORD",
);

/**
 * "Continue with Google". Everything about the person comes from the verified ID token.
 * 1. A user already linked to this Google account (by `sub`) is signed in.
 * 2. If another account already uses the email, nothing is linked or merged: an email match alone
 *    must never hand over an existing account. Linking needs a separate, signed-in flow.
 * 3. Otherwise a new, password-less account is created.
 * The result is the same Child Assist JWT as password login.
 */
export async function googleLogin(input: GoogleLoginInput): Promise<AuthResult> {
  const identity = await verifyGoogleIdToken(input.idToken);

  const linked = await prisma.user.findUnique({ where: { googleSubject: identity.subject }, select: safeUserSelect });
  if (linked) return signedIn(linked);

  const sameEmail = await prisma.user.findUnique({ where: { email: identity.email }, select: { id: true } });
  if (sameEmail) throw ACCOUNT_EXISTS;

  try {
    const user = await prisma.user.create({
      // Google only issues tokens with email_verified for addresses it has verified, so no code is needed.
      data: {
        name: identity.name,
        email: identity.email,
        googleSubject: identity.subject,
        passwordHash: null,
        emailVerified: true,
      },
      select: safeUserSelect,
    });
    return signedIn(user);
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
      // A concurrent request created the account first: sign in to it if it is this Google
      // account, otherwise the email was taken in the meantime.
      const created = await prisma.user.findUnique({ where: { googleSubject: identity.subject }, select: safeUserSelect });
      if (created) return signedIn(created);
      throw ACCOUNT_EXISTS;
    }
    throw err;
  }
}

export async function getUserById(userId: string): Promise<SafeUser> {
  const user = await prisma.user.findUnique({ where: { id: userId }, select: safeUserSelect });
  if (!user) {
    // Token is valid but the account no longer exists.
    throw new HttpError(401, "Invalid or expired token");
  }
  return user;
}
