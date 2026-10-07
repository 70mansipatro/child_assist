import { z } from "zod";
import { listPermissions } from "../../permissions/permissions.service";
import { getProfile } from "../../profile/profile.service";
import { defineChatTool } from "./define-tool";
import { ok, type ToolContext } from "./types";

export function accountTools(ctx: ToolContext) {
  return {
    get_profile: defineChatTool(ctx, {
      name: "get_profile",
      kind: "profile",
      description: "Get the signed-in user's basic profile: their name and email.",
      inputSchema: z.strictObject({}),
      execute: async (_input, { userId }) => {
        const profile = await getProfile(userId);
        // No internal IDs and no image URL: the model only needs what it may say to the user.
        return ok({
          name: profile.name,
          email: profile.email,
          hasProfilePhoto: profile.profileImageUrl !== null,
        });
      },
    }),

    get_permissions: defineChatTool(ctx, {
      name: "get_permissions",
      kind: "permissions",
      description:
        "Get which device permissions the user has granted to the Child Assist app " +
        "(LOCATION, PHOTOS, DOCUMENTS, CAMERA, MICROPHONE, NOTIFICATIONS, CONTACTS). Use it to explain why " +
        "something cannot be accessed. Permissions are changed by the user in the app, never by you.",
      inputSchema: z.strictObject({}),
      execute: async (_input, { userId }) => {
        const permissions = await listPermissions(userId);
        return ok({ permissions: permissions.map(({ permission, status }) => ({ permission, status })) });
      },
    }),
  };
}
