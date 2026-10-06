import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as profileService from "./profile.service";
import { permissionOnboardingSchema, updateProfileSchema } from "./profile.validation";

// The user is always the one identified by the verified JWT, never an ID from the request.

export async function getProfile(req: Request, res: Response): Promise<void> {
  const user = await profileService.getProfile(getAuth(req).userId);
  res.status(200).json({ user });
}

export async function updateProfile(req: Request, res: Response): Promise<void> {
  const input = updateProfileSchema.parse(req.body);
  const user = await profileService.updateProfile(getAuth(req).userId, input);
  res.status(200).json({ user });
}

export async function updatePermissionOnboarding(req: Request, res: Response): Promise<void> {
  const input = permissionOnboardingSchema.parse(req.body);
  const user = await profileService.setPermissionOnboarding(getAuth(req).userId, input);
  res.status(200).json({ user });
}
