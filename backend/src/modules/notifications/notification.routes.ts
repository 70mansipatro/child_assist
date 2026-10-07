import { Router, type Request } from "express";
import { getAuth, requireAuth } from "../../middleware/auth.middleware";
import { rateLimit } from "../../middleware/rate-limit.middleware";
import * as controller from "./notification.controller";

export const notificationsRouter = Router();

notificationsRouter.use(requireAuth);

// Per account (after requireAuth), so phones sharing a network don't share a limit.
const perUser = (bucket: string, max: number, windowMs: number) =>
  rateLimit({ bucket, max, windowMs, key: (req: Request) => getAuth(req).userId });
const MINUTE = 60_000;

const deviceLimit = perUser("notification-devices", 20, 15 * MINUTE);
const preferenceLimit = perUser("notification-preferences", 30, 15 * MINUTE);
const readLimit = perUser("notification-read", 300, 5 * MINUTE);
const writeLimit = perUser("notification-write", 200, 5 * MINUTE);

notificationsRouter.post("/devices", deviceLimit, controller.registerDevice);
notificationsRouter.delete("/devices/:id", deviceLimit, controller.unregisterDevice);

notificationsRouter.get("/preferences", readLimit, controller.getPreferences);
notificationsRouter.patch("/preferences", preferenceLimit, controller.updatePreferences);

notificationsRouter.get("/", readLimit, controller.list);
notificationsRouter.get("/unread-count", readLimit, controller.unreadCount);
notificationsRouter.patch("/read-all", writeLimit, controller.markAllRead);
notificationsRouter.delete("/", writeLimit, controller.clear);
// Registered after the fixed paths above so none of them is treated as an ID.
notificationsRouter.patch("/:id/read", writeLimit, controller.markRead);
notificationsRouter.delete("/:id", writeLimit, controller.remove);
