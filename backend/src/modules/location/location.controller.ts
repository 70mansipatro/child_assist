import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as locationService from "./location.service";
import {
  createLocationSchema,
  deleteHistoryQuerySchema,
  historyQuerySchema,
  locationParamsSchema,
  resolveHistoryQuery,
} from "./location.validation";

// The user is always the one identified by the verified JWT, never an ID from the request.

export async function saveLocation(req: Request, res: Response): Promise<void> {
  const input = createLocationSchema.parse(req.body);
  const result = await locationService.saveLocation(getAuth(req).userId, input);
  // A skipped duplicate is not an error: the place is already in the history, so the app can drop
  // the point from its queue. 201 only when a row was created.
  res.status(result.saved ? 201 : 200).json(result);
}

export async function listHistory(req: Request, res: Response): Promise<void> {
  const { range, ...options } = resolveHistoryQuery(historyQuerySchema.parse(req.query));
  // A date search reads like a diary (oldest first); recent history stays newest first.
  const { locations, hasMore } = await locationService.searchLocations(getAuth(req).userId, {
    ...options,
    order: range ? "asc" : "desc",
  });
  res.status(200).json({ locations, hasMore, ...(range ? { range } : {}) });
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
