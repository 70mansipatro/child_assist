import { Prisma } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import type { UpdateProfileInput } from "./profile.validation";

// The only profile fields ever returned to clients. passwordHash is never part of this.
const safeProfileSelect = { id: true, name: true, email: true, profileImageUrl: true } as const;

export type SafeProfile = Prisma.UserGetPayload<{ select: typeof safeProfileSelect }>;

export async function getProfile(userId: string): Promise<SafeProfile> {
  const user = await prisma.user.findUnique({ where: { id: userId }, select: safeProfileSelect });
  if (!user) {
    // Token is valid but the account no longer exists.
    throw new HttpError(401, "Invalid or expired token");
  }
  return user;
}

export async function updateProfile(userId: string, input: UpdateProfileInput): Promise<SafeProfile> {
  try {
    return await prisma.user.update({
      where: { id: userId },
      // Only whitelisted fields are copied; the schema already rejects anything else.
      data: { name: input.name, profileImageUrl: input.profileImageUrl },
      select: safeProfileSelect,
    });
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2025") {
      throw new HttpError(401, "Invalid or expired token");
    }
    throw err;
  }
}
