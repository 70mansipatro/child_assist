import { Router } from "express";
import { requireAuth } from "../../middleware/auth.middleware";
import * as profileController from "./profile.controller";

export const profileRouter = Router();

profileRouter.use(requireAuth);
profileRouter.get("/", profileController.getProfile);
profileRouter.patch("/", profileController.updateProfile);
profileRouter.patch("/permission-onboarding", profileController.updatePermissionOnboarding);
