import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as permissionsService from "./permissions.service";
import { permissionParamsSchema, updatePermissionSchema } from "./permissions.validation";

// The user is always the one identified by the verified JWT, never an ID from the request.

export async function listPermissions(req: Request, res: Response): Promise<void> {
  const permissions = await permissionsService.listPermissions(getAuth(req).userId);
  res.status(200).json({ permissions });
}

export async function updatePermission(req: Request, res: Response): Promise<void> {
  const { permission } = permissionParamsSchema.parse(req.params);
  const { status } = updatePermissionSchema.parse(req.body);
  const record = await permissionsService.setPermissionStatus(getAuth(req).userId, permission, status);
  res.status(200).json(record);
}
