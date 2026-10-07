import { Router } from "express";
import { automaticLocationConfig } from "../../config/env";
import { getAuth, requireAuth } from "../../middleware/auth.middleware";
import { rateLimit } from "../../middleware/rate-limit.middleware";
import { trackingStatus } from "../notifications/notification.controller";
import * as locationController from "./location.controller";

export const locationRouter = Router();

locationRouter.use(requireAuth);
// Per account (after requireAuth), generous enough for automatic history and a phone uploading its
// offline queue, but stops a client that sends far more than any real movement could produce.
locationRouter.post(
  "/",
  rateLimit(() => {
    const config = automaticLocationConfig();
    return {
      bucket: "location-save",
      max: config.rateLimitMax,
      windowMs: config.rateLimitWindowMs,
      key: (req) => getAuth(req).userId,
    };
  }),
  locationController.saveLocation,
);
// Automatic Location History reports its state (started, stopped, paused); only real changes
// notify the user. Never carries a location.
locationRouter.post(
  "/tracking-status",
  rateLimit({ bucket: "tracking-status", max: 30, windowMs: 10 * 60_000, key: (req) => getAuth(req).userId }),
  trackingStatus,
);
locationRouter.get("/history", locationController.listHistory);
locationRouter.delete("/history", locationController.deleteHistory);
// Registered after /history so that path is never treated as an ID.
locationRouter.delete("/:id", locationController.deleteLocation);
