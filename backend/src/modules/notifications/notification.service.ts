import { DevicePlatform, NotificationType, Prisma, type Notification } from "../../../generated/prisma/client";
import { HttpError } from "../../lib/http-error";
import { prisma } from "../../lib/prisma";
import { pushAvailable, sendPush, type PushMessage } from "./fcm.service";
import {
  ANDROID_CHANNEL,
  CATEGORY_OF,
  MANDATORY_CATEGORIES,
  NotificationCategory,
  isHighPriority,
  isSafeContent,
  templates,
  type NotificationContent,
} from "./notification.types";

// Every query here is scoped by the userId passed in, which callers take from the verified JWT
// (or, for business events, from the account the event happened to). Never from a request body.
//
// Business event -> notifyUser -> preference check -> history row -> active devices -> FCM ->
// invalid tokens removed. Delivery is secondary: callers use notifyInBackground, so a failed push
// never fails the password reset, login or email that caused it.

// ---------------------------------------------------------------------------------------------
// Preferences

export interface PreferencesView {
  securityEnabled: boolean;
  accountEnabled: boolean;
  permissionEnabled: boolean;
  locationEnabled: boolean;
  chatEnabled: boolean;
  communicationEnabled: boolean;
  systemEnabled: boolean;
  /** Categories the user cannot switch off. */
  mandatory: NotificationCategory[];
}

const PREFERENCE_FIELD: Record<NotificationCategory, keyof Omit<PreferencesView, "mandatory">> = {
  SECURITY: "securityEnabled",
  ACCOUNT: "accountEnabled",
  PERMISSION: "permissionEnabled",
  LOCATION: "locationEnabled",
  CHAT: "chatEnabled",
  COMMUNICATION: "communicationEnabled",
  SYSTEM: "systemEnabled",
};

const preferenceSelect = {
  securityEnabled: true,
  accountEnabled: true,
  permissionEnabled: true,
  locationEnabled: true,
  chatEnabled: true,
  communicationEnabled: true,
  systemEnabled: true,
} as const;

const DEFAULT_PREFERENCES = {
  securityEnabled: true,
  accountEnabled: true,
  permissionEnabled: true,
  locationEnabled: true,
  chatEnabled: true,
  communicationEnabled: true,
  systemEnabled: true,
};

const MANDATORY = [...MANDATORY_CATEGORIES];

/** The user's switches; all on until they change one (no row is written just by reading). */
export async function getPreferences(userId: string): Promise<PreferencesView> {
  const row = await prisma.notificationPreference.findUnique({ where: { userId }, select: preferenceSelect });
  return { ...(row ?? DEFAULT_PREFERENCES), securityEnabled: true, mandatory: MANDATORY };
}

export type PreferencesUpdate = Partial<Omit<PreferencesView, "mandatory">>;

export async function updatePreferences(userId: string, update: PreferencesUpdate): Promise<PreferencesView> {
  for (const category of MANDATORY_CATEGORIES) {
    if (update[PREFERENCE_FIELD[category]] === false) {
      throw new HttpError(400, "Security alerts can't be turned off.", "MANDATORY_CATEGORY");
    }
  }
  try {
    await prisma.notificationPreference.upsert({
      where: { userId },
      create: { ...DEFAULT_PREFERENCES, ...update, securityEnabled: true, userId },
      update: { ...update, securityEnabled: true },
    });
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2003") {
      throw new HttpError(401, "Invalid or expired token");
    }
    throw err;
  }
  return getPreferences(userId);
}

async function categoryEnabled(userId: string, category: NotificationCategory): Promise<boolean> {
  if (MANDATORY_CATEGORIES.has(category)) return true;
  const prefs = await getPreferences(userId);
  return prefs[PREFERENCE_FIELD[category]];
}

// ---------------------------------------------------------------------------------------------
// Devices

export interface DeviceView {
  id: string;
  platform: DevicePlatform;
  appVersion: string | null;
  enabled: boolean;
  lastSeenAt: Date;
  createdAt: Date;
}

const deviceSelect = { id: true, platform: true, appVersion: true, enabled: true, lastSeenAt: true, createdAt: true } as const;

/**
 * Registers this phone's FCM token for the signed-in user. A token belongs to one account at a
 * time: if another account registered it before (an account switch on the same phone), the row
 * moves to this user, so the previous account's notifications stop reaching this phone. A token
 * is never duplicated; a refreshed token is simply a new registration and the old one is removed
 * by the app or, at the latest, when FCM reports it invalid.
 */
export async function registerDevice(
  userId: string,
  input: { token: string; platform: DevicePlatform; appVersion?: string | null },
): Promise<DeviceView> {
  const now = new Date();
  const data = { userId, platform: input.platform, appVersion: input.appVersion ?? null, enabled: true, lastSeenAt: now };
  try {
    return await prisma.notificationDevice.upsert({
      where: { token: input.token },
      create: { ...data, token: input.token },
      update: data,
      select: deviceSelect,
    });
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError) {
      if (err.code === "P2003") throw new HttpError(401, "Invalid or expired token");
      // Two registrations of the same new token raced; the other one created it.
      if (err.code === "P2002") {
        return prisma.notificationDevice.update({ where: { token: input.token }, data, select: deviceSelect });
      }
    }
    throw err;
  }
}

/** Removes one of the user's own devices (logout). Another account's device looks missing. */
export async function unregisterDevice(userId: string, deviceId: string): Promise<void> {
  const { count } = await prisma.notificationDevice.deleteMany({ where: { id: deviceId, userId } });
  if (count === 0) throw new HttpError(404, "Device not found");
}

// ---------------------------------------------------------------------------------------------
// Sending

export type NotifyOutcome =
  | { status: "created"; notificationId: string; sent: number; failed: number; removedDevices: number }
  | { status: "skipped"; reason: "preference-disabled" | "duplicate" };

export interface NotifyOptions {
  /**
   * One business event, one notification: a second call with the same key for the same user does
   * nothing (e.g. a retried request, or tracking reporting "started" twice).
   */
  dedupeKey?: string;
}

/** Saves [content] to the user's history and pushes it to all their devices. */
export async function notifyUser(userId: string, content: NotificationContent, options: NotifyOptions = {}): Promise<NotifyOutcome> {
  if (!isSafeContent(content)) throw new Error(`Refused unsafe notification content (${content.type})`);
  const category = CATEGORY_OF[content.type];
  if (!(await categoryEnabled(userId, category))) return { status: "skipped", reason: "preference-disabled" };

  // INSERT ... ON CONFLICT DO NOTHING: a repeated event (same dedupe key) inserts nothing.
  const [notification]: Notification[] = await prisma.notification.createManyAndReturn({
    data: [
      {
        userId,
        type: content.type,
        title: content.title,
        body: content.body,
        deepLink: content.deepLink,
        metadataJson: content.metadata ?? Prisma.JsonNull,
        dedupeKey: options.dedupeKey ?? null,
      },
    ],
    skipDuplicates: true,
  });
  if (!notification) return { status: "skipped", reason: "duplicate" };

  const devices = await prisma.notificationDevice.findMany({
    where: { userId, enabled: true },
    select: { id: true, token: true },
  });
  if (devices.length === 0 || !pushAvailable()) {
    return { status: "created", notificationId: notification.id, sent: 0, failed: 0, removedDevices: 0 };
  }

  const messages: PushMessage[] = devices.map((d) => ({
    token: d.token,
    title: notification.title,
    body: notification.body,
    data: {
      notificationId: notification.id,
      type: notification.type,
      category,
      deepLink: notification.deepLink ?? "",
    },
    androidChannelId: ANDROID_CHANNEL[category],
    highPriority: isHighPriority(notification.type),
  }));
  const results = await sendPush(messages);

  // Tokens FCM says will never work again are removed. Matched on the token too, so a device that
  // was re-registered in the meantime is left alone.
  const invalid = devices.filter((_, i) => {
    const r = results[i];
    return r && !r.ok && r.invalidToken;
  });
  let removedDevices = 0;
  for (const device of invalid) {
    removedDevices += (await prisma.notificationDevice.deleteMany({ where: { id: device.id, token: device.token } })).count;
  }
  const sent = results.filter((r) => r.ok).length;
  const failed = results.length - sent;
  if (failed > removedDevices) {
    // Only codes: never the token or the content.
    const codes = [...new Set(results.flatMap((r) => (r.ok ? [] : [r.errorCode])))].join(", ");
    console.warn(`Push delivery failed for ${failed - removedDevices} device(s): ${codes}`);
  }
  return { status: "created", notificationId: notification.id, sent, failed, removedDevices };
}

const inFlight = new Set<Promise<unknown>>();

/**
 * Fire and forget: the business operation that caused the notification never waits for FCM and
 * never fails because of it. Errors are logged by name only.
 */
export function notifyInBackground(userId: string, content: NotificationContent, options: NotifyOptions = {}): void {
  const task = notifyUser(userId, content, options)
    .catch((err) => {
      // A deleted account (foreign key) is not worth logging.
      if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2003") return;
      const e = err instanceof Error ? err : new Error(String(err));
      console.error(`Notification ${content.type} failed: ${e.name}: ${e.message}`);
    })
    .finally(() => inFlight.delete(task));
  inFlight.add(task);
}

/** Waits for every background notification started so far. For tests and graceful shutdown. */
export async function settleNotifications(): Promise<void> {
  while (inFlight.size > 0) await Promise.allSettled([...inFlight]);
}

// ---------------------------------------------------------------------------------------------
// Automatic Location History state

export const TrackingState = { STARTED: "STARTED", STOPPED: "STOPPED", PAUSED: "PAUSED" } as const;
export type TrackingState = (typeof TrackingState)[keyof typeof TrackingState];

const TRACKING_TEMPLATE: Record<TrackingState, () => NotificationContent> = {
  STARTED: templates.trackingStarted,
  STOPPED: templates.trackingStopped,
  PAUSED: templates.trackingPaused,
};

const TRACKING_TYPES = [NotificationType.TRACKING_STARTED, NotificationType.TRACKING_STOPPED, NotificationType.TRACKING_PAUSED];

/**
 * The phone reports what Automatic Location History is doing. Only a real change notifies: the app
 * reports "started" on every launch and background callbacks may repeat it, so a state equal to the
 * last one notified is ignored. The key includes the previous notification, so two concurrent
 * reports of the same change still create one notification.
 */
export async function notifyTrackingState(userId: string, state: TrackingState): Promise<NotifyOutcome> {
  const content = TRACKING_TEMPLATE[state]();
  const last = await prisma.notification.findFirst({
    where: { userId, type: { in: TRACKING_TYPES } },
    orderBy: [{ createdAt: "desc" }, { id: "desc" }],
    select: { id: true, type: true },
  });
  if (last?.type === content.type) return { status: "skipped", reason: "duplicate" };
  // Nothing to say about "stopped" or "paused" if tracking was never reported as started.
  if (!last && state !== TrackingState.STARTED) return { status: "skipped", reason: "duplicate" };
  return notifyUser(userId, content, { dedupeKey: `tracking:after:${last?.id ?? "none"}` });
}

// ---------------------------------------------------------------------------------------------
// History

export interface NotificationView {
  id: string;
  type: NotificationType;
  category: NotificationCategory;
  title: string;
  body: string;
  deepLink: string | null;
  read: boolean;
  readAt: Date | null;
  createdAt: Date;
}

const notificationSelect = {
  id: true,
  type: true,
  title: true,
  body: true,
  deepLink: true,
  readAt: true,
  createdAt: true,
} as const;

type NotificationRow = Prisma.NotificationGetPayload<{ select: typeof notificationSelect }>;

function toView(row: NotificationRow): NotificationView {
  return {
    id: row.id,
    type: row.type,
    category: CATEGORY_OF[row.type],
    title: row.title,
    body: row.body,
    deepLink: row.deepLink,
    read: row.readAt !== null,
    readAt: row.readAt,
    createdAt: row.createdAt,
  };
}

export async function listNotifications(
  userId: string,
  options: { limit: number; before?: string; unreadOnly?: boolean },
): Promise<{ notifications: NotificationView[]; hasMore: boolean; unreadCount: number }> {
  let cursor: { createdAt: Date; id: string } | null = null;
  if (options.before) {
    cursor = await prisma.notification.findFirst({ where: { id: options.before, userId }, select: { createdAt: true, id: true } });
    if (!cursor) throw new HttpError(400, "Invalid cursor", "INVALID_CURSOR");
  }
  const rows = await prisma.notification.findMany({
    where: {
      userId,
      ...(options.unreadOnly ? { readAt: null } : {}),
      ...(cursor
        ? { OR: [{ createdAt: { lt: cursor.createdAt } }, { createdAt: cursor.createdAt, id: { lt: cursor.id } }] }
        : {}),
    },
    orderBy: [{ createdAt: "desc" }, { id: "desc" }],
    take: options.limit + 1,
    select: notificationSelect,
  });
  return {
    notifications: rows.slice(0, options.limit).map(toView),
    hasMore: rows.length > options.limit,
    unreadCount: await unreadCount(userId),
  };
}

export async function unreadCount(userId: string): Promise<number> {
  return prisma.notification.count({ where: { userId, readAt: null } });
}

const notFound = () => new HttpError(404, "Notification not found");

/** Marks one of the user's notifications read. Already read stays as it was. */
export async function markRead(userId: string, id: string): Promise<NotificationView> {
  await prisma.notification.updateMany({ where: { id, userId, readAt: null }, data: { readAt: new Date() } });
  const row = await prisma.notification.findFirst({ where: { id, userId }, select: notificationSelect });
  if (!row) throw notFound();
  return toView(row);
}

export async function markAllRead(userId: string): Promise<number> {
  const { count } = await prisma.notification.updateMany({ where: { userId, readAt: null }, data: { readAt: new Date() } });
  return count;
}

export async function deleteNotification(userId: string, id: string): Promise<void> {
  const { count } = await prisma.notification.deleteMany({ where: { id, userId } });
  if (count === 0) throw notFound();
}

export async function clearNotifications(userId: string): Promise<number> {
  const { count } = await prisma.notification.deleteMany({ where: { userId } });
  return count;
}
