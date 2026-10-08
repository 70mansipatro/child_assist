import type { ToolSet } from "ai";
import { accountTools } from "./account.tools";
import { communicationTools, webTools } from "./communication.tools";
import { deviceTools } from "./device.tools";
import { locationTools } from "./location.tools";
import { photoTools } from "./photo.tools";
import type { ToolContext } from "./types";

/**
 * The only ways Gemini can reach user data. Built per request around the authenticated user, so
 * the model never sees, chooses or overrides whose data a tool reads.
 */
export function buildChatTools(ctx: ToolContext): ToolSet {
  return {
    ...accountTools(ctx),
    ...locationTools(ctx),
    ...deviceTools(ctx),
    ...photoTools(ctx),
    ...webTools(ctx),
    ...communicationTools(ctx),
  };
}
