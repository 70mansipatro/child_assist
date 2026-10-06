import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as locationService from "./location.service";
import {
  createLocationSchema,
  deleteHistoryQuerySchema,
  historyQuerySchema,
  locationParamsSchema,
} from "./location.validation";

// The user is always the one identified by the verified JWT, never an ID from the request.

export async function saveLocation(req: Request, res: Response): Promise<void> {
  const input = createLocationSchema.parse(req.body);
  const location = await locationService.saveLocation(getAuth(req).userId, input);
  res.status(201).json({ location });
}

export async function listHistory(req: Request, res: Response): Promise<void> {
  const options = historyQuerySchema.parse(req.query);
  const locations = await locationService.listLocations(getAuth(req).userId, options);
  res.status(200).json({ locations });
}

export async function deleteHistory(req: Request, res: Response): Promise<void> {
  deleteHistoryQuerySchema.parse(req.query);
  const deleted = await locationService.deleteHistory(getAuth(req).userId);
  res.status(200).json({ deleted });
}

export async function deleteLocation(req: Request, res: Response): Promise<void> {
  const { id } = locationParamsSchema.parse(req.params);
  await locationService.deleteLocation(getAuth(req).userId, id);
  res.status(200).json({ deleted: 1 });
}
