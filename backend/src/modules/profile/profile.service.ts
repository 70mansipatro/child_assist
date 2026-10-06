import { Prisma } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import type { PermissionOnboardingInput, UpdateProfileInput } from "./profile.validation";

// The only profile fields ever returned to clients. passwordHash is never part of this.
const safeProfileSelect = {
  id: true,
  name: true,
  email: true,
  profileImageUrl: true,
  permissionOnboardingCompleted: true,
} as const;

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
  // Only whitelisted fields are copied; the schema already rejects anything else.
  return updateUser(userId, { name: input.name, profileImageUrl: input.profileImageUrl });
}

/** Records whether the user has finished the first-time permission walkthrough. */
export async function setPermissionOnboarding(
  userId: string,
  input: PermissionOnboardingInput,
): Promise<SafeProfile> {
  return updateUser(userId, { permissionOnboardingCompleted: input.completed });
}

async function updateUser(userId: string, data: Prisma.UserUpdateInput): Promise<SafeProfile> {
  try {
    return await prisma.user.update({ where: { id: userId }, data, select: safeProfileSelect });
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2025") {
      throw new HttpError(401, "Invalid or expired token");
    }
    throw err;
  }
}
