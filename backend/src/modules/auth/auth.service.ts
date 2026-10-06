import bcrypt from "bcryptjs";
import { Prisma } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import { signAccessToken } from "../../lib/jwt";
import type { LoginInput, RegisterInput } from "./auth.validation";

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
  if (!user || !user.passwordHash || !passwordOk) {
    throw new HttpError(401, "Invalid email or password");
  }

  return {
    user: { id: user.id, name: user.name, email: user.email },
    token: signAccessToken(user.id),
  };
}

export async function getUserById(userId: string): Promise<SafeUser> {
  const user = await prisma.user.findUnique({ where: { id: userId }, select: safeUserSelect });
  if (!user) {
    // Token is valid but the account no longer exists.
    throw new HttpError(401, "Invalid or expired token");
  }
  return user;
}
