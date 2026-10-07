import { PermissionStatus, PermissionType } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { notifyInBackground } from "../notifications/notification.service";
import { templates } from "../notifications/notification.types";

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

const USABLE: ReadonlySet<PermissionStatus> = new Set([PermissionStatus.GRANTED, PermissionStatus.LIMITED]);
const REVOKED: ReadonlySet<PermissionStatus> = new Set([PermissionStatus.DENIED, PermissionStatus.RESTRICTED]);

/**
 * Records the status the device reported. This never grants an OS permission. When a permission
 * that was allowed is reported as denied, the user is told (once per change) which one: never
 * anything the permission gave access to.
 */
export async function setPermissionStatus(
  userId: string,
  permission: PermissionType,
  status: PermissionStatus,
): Promise<PermissionRecord> {
  const previous = await prisma.userPermission.findUnique({
    where: { userId_permission: { userId, permission } },
    select: { status: true, updatedAt: true },
  });
  // The (userId, permission) unique index keeps exactly one row per user and permission.
  const record = await prisma.userPermission.upsert({
    where: { userId_permission: { userId, permission } },
    create: { userId, permission, status },
    update: { status },
    select: { permission: true, status: true, updatedAt: true },
  });
  if (previous && USABLE.has(previous.status) && REVOKED.has(status)) {
    // Keyed on the state it changed from, so a retried report of the same change notifies once.
    notifyInBackground(userId, templates.permissionDisabled(permission), {
      dedupeKey: `permission:${permission}:revoked:${previous.updatedAt.toISOString()}`,
    });
  }
  return record;
}
