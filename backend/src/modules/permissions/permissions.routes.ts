import { Router } from "express";
import { requireAuth } from "../../middleware/auth.middleware";
import * as permissionsController from "./permissions.controller";

export const permissionsRouter = Router();

permissionsRouter.use(requireAuth);
permissionsRouter.get("/", permissionsController.listPermissions);
permissionsRouter.patch("/:permission", permissionsController.updatePermission);
