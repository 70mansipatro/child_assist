import { z } from "zod";
import { PermissionStatus, PermissionType } from "../../../generated/prisma/client";

export const permissionParamsSchema = z.object({
  permission: z.enum(PermissionType, {
    error: `Permission must be one of: ${Object.values(PermissionType).join(", ")}`,
  }),
});

export const updatePermissionSchema = z.strictObject(
  {
    status: z.enum(PermissionStatus, {
      error: `Status must be one of: ${Object.values(PermissionStatus).join(", ")}`,
    }),
  },
  { error: "Request body must be a JSON object" },
);

export type UpdatePermissionInput = z.infer<typeof updatePermissionSchema>;
