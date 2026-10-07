import bcrypt from "bcryptjs";
import { Prisma } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import { signAccessToken } from "../../lib/jwt";
import { verifyGoogleIdToken } from "../../lib/google-token";
import type { GoogleLoginInput, LoginInput, RegisterInput } from "./auth.validation";

const BCRYPT_ROUNDS = 12;

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

export async function register(input: RegisterInput): Promise<AuthResult> {
  const existing = await prisma.user.findUnique({ where: { email: input.email }, select: { id: true } });
  if (existing) {
    throw new HttpError(409, "Email already registered");
  }

  const passwordHash = await bcrypt.hash(input.password, BCRYPT_ROUNDS);

  try {
    const user = await prisma.user.create({
      data: { name: input.name, email: input.email, passwordHash },
      select: safeUserSelect,
    });
    return { user, token: signAccessToken(user.id) };
  } catch (err) {
    // Two concurrent registrations can both pass the check above; the unique index catches it.
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
      throw new HttpError(409, "Email already registered");
    }
    throw err;
  }
}

export async function login(input: LoginInput): Promise<AuthResult> {
  const user = await prisma.user.findUnique({
    where: { email: input.email },
    select: { ...safeUserSelect, passwordHash: true },
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

  return {
    user: { id: user.id, name: user.name, email: user.email },
    token: signAccessToken(user.id),
  };
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
  if (linked) return { user: linked, token: signAccessToken(linked.id) };

  const sameEmail = await prisma.user.findUnique({ where: { email: identity.email }, select: { id: true } });
  if (sameEmail) throw ACCOUNT_EXISTS;

  try {
    const user = await prisma.user.create({
      data: { name: identity.name, email: identity.email, googleSubject: identity.subject, passwordHash: null },
      select: safeUserSelect,
    });
    return { user, token: signAccessToken(user.id) };
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
      // A concurrent request created the account first: sign in to it if it is this Google
      // account, otherwise the email was taken in the meantime.
      const created = await prisma.user.findUnique({ where: { googleSubject: identity.subject }, select: safeUserSelect });
      if (created) return { user: created, token: signAccessToken(created.id) };
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
