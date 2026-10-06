import { Router } from "express";
import { requireAuth } from "../../middleware/auth.middleware";
import * as locationController from "./location.controller";

export const locationRouter = Router();

locationRouter.use(requireAuth);
locationRouter.post("/", locationController.saveLocation);
locationRouter.get("/history", locationController.listHistory);
locationRouter.delete("/history", locationController.deleteHistory);
// Registered after /history so that path is never treated as an ID.
locationRouter.delete("/:id", locationController.deleteLocation);
