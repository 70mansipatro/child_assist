import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as notificationService from "./notification.service";
import {
  emptyQuerySchema,
  idParamsSchema,
  listQuerySchema,
  registerDeviceSchema,
  trackingStatusSchema,
  updatePreferencesSchema,
} from "./notification.validation";

// The user is always the one identified by the verified JWT, never an ID from the request.

/** Development-only diagnostics; never the token itself. */
const diag = (message: string) => {
  if (process.env.NODE_ENV === "development") console.log(`[notifications] ${message}`);
};
const maskToken = (token: unknown) =>
  typeof token === "string" && token.length >= 16 ? `len=${token.length} ${token.slice(0, 6)}...${token.slice(-4)}` : "invalid";

export async function registerDevice(req: Request, res: Response): Promise<void> {
  const userId = getAuth(req).userId;
  diag(`device registration from user ${userId}, token ${maskToken(req.body?.token)}, platform ${String(req.body?.platform)}`);
  const parsed = registerDeviceSchema.safeParse(req.body);
  if (!parsed.success) {
    diag(`device registration rejected: ${parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")}`);
    throw parsed.error;
  }
  try {
    const device = await notificationService.registerDevice(userId, parsed.data);
    diag(`NotificationDevice upsert ok: device ${device.id} for user ${userId}`);
    res.status(200).json({ device });
  } catch (err) {
    diag(`NotificationDevice upsert failed for user ${userId}: ${err instanceof Error ? err.name : "unknown"}`);
    throw err;
  }
}

export async function unregisterDevice(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  await notificationService.unregisterDevice(getAuth(req).userId, id);
  res.status(200).json({ deleted: 1 });
}

export async function list(req: Request, res: Response): Promise<void> {
  const query = listQuerySchema.parse(req.query);
  const result = await notificationService.listNotifications(getAuth(req).userId, {
    limit: query.limit,
    before: query.before,
    unreadOnly: query.unread === "true",
  });
  res.status(200).json(result);
}

export async function unreadCount(req: Request, res: Response): Promise<void> {
  emptyQuerySchema.parse(req.query);
  res.status(200).json({ unreadCount: await notificationService.unreadCount(getAuth(req).userId) });
}

export async function markRead(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const notification = await notificationService.markRead(getAuth(req).userId, id);
  res.status(200).json({ notification });
}

export async function markAllRead(req: Request, res: Response): Promise<void> {
  emptyQuerySchema.parse(req.query);
  res.status(200).json({ updated: await notificationService.markAllRead(getAuth(req).userId) });
}

export async function remove(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  await notificationService.deleteNotification(getAuth(req).userId, id);
  res.status(200).json({ deleted: 1 });
}

export async function clear(req: Request, res: Response): Promise<void> {
  emptyQuerySchema.parse(req.query);
  res.status(200).json({ deleted: await notificationService.clearNotifications(getAuth(req).userId) });
}

export async function getPreferences(req: Request, res: Response): Promise<void> {
  emptyQuerySchema.parse(req.query);
  res.status(200).json({ preferences: await notificationService.getPreferences(getAuth(req).userId) });
}

export async function updatePreferences(req: Request, res: Response): Promise<void> {
  const update = updatePreferencesSchema.parse(req.body);
  res.status(200).json({ preferences: await notificationService.updatePreferences(getAuth(req).userId, update) });
}

/** The phone reports Automatic Location History's state; the server decides what to say. */
export async function trackingStatus(req: Request, res: Response): Promise<void> {
  const { state } = trackingStatusSchema.parse(req.body);
  const outcome = await notificationService.notifyTrackingState(getAuth(req).userId, state);
  res.status(200).json({ notified: outcome.status === "created" });
}
