import { PermissionStatus, PermissionType } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";

export interface PermissionRecord {
  permission: PermissionType;
  status: PermissionStatus;
  /** When the app last reported this status; null if it never has. */
  updatedAt: Date | null;
}

/**
 * Returns every supported permission for the user. Permissions the app has never
 * reported are listed as UNKNOWN without writing a row.
 */
export async function listPermissions(userId: string): Promise<PermissionRecord[]> {
  const rows = await prisma.userPermission.findMany({
    where: { userId },
    select: { permission: true, status: true, updatedAt: true },
  });
  const byType = new Map(rows.map((r) => [r.permission, r]));

  return Object.values(PermissionType).map(
    (permission) =>
      byType.get(permission) ?? { permission, status: PermissionStatus.UNKNOWN, updatedAt: null },
  );
}

/** Records the status the device reported. This never grants an OS permission. */
export async function setPermissionStatus(
  userId: string,
  permission: PermissionType,
  status: PermissionStatus,
): Promise<PermissionRecord> {
  // The (userId, permission) unique index keeps exactly one row per user and permission.
  return prisma.userPermission.upsert({
    where: { userId_permission: { userId, permission } },
    create: { userId, permission, status },
    update: { status },
    select: { permission: true, status: true, updatedAt: true },
  });
}
