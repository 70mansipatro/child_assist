import { tool, type Tool } from "ai";
import type { z } from "zod";
import { PermissionStatus, PermissionType } from "../../../../generated/prisma/client";
import { prisma } from "../../../lib/prisma";
import { recordToolCall, type ToolCallStatus } from "../chat.service";
import { fail, type ToolContext, type ToolEvent, type ToolEventKind, type ToolEventStatus, type ToolResult } from "./types";

// Permission statuses that let a tool read the matching data. LIMITED is iOS "selected photos
// only": the device itself restricts what is visible, so reading within it is fine.
const ALLOWING_STATUSES: ReadonlySet<PermissionStatus> = new Set([PermissionStatus.GRANTED, PermissionStatus.LIMITED]);

/**
 * The device permission status the app last reported. Missing means the user never granted it.
 * This is the backend's check and always wins, whatever the model or the message says.
 *
 * DOCUMENTS is the exception: there is no OS runtime permission for it. The OS grants access
 * per file when the user picks it in the system file picker, so the app never reports a status
 * and only an explicit DENIED/RESTRICTED blocks it.
 */
export async function hasPermission(userId: string, permission: PermissionType): Promise<boolean> {
  const row = await prisma.userPermission.findUnique({
    where: { userId_permission: { userId, permission } },
    select: { status: true },
  });
  if (permission === PermissionType.DOCUMENTS) {
    return row === null || (row.status !== PermissionStatus.DENIED && row.status !== PermissionStatus.RESTRICTED);
  }
  return row !== null && ALLOWING_STATUSES.has(row.status);
}

export function permissionRequired(permission: PermissionType): ReturnType<typeof fail> {
  return fail("PERMISSION_REQUIRED", `The ${permission} permission has not been granted in the Child Assist app.`, {
    permission,
  });
}

interface ChatToolSpec<INPUT> {
  name: string;
  description: string;
  inputSchema: z.ZodType<INPUT>;
  /** Checked before execute runs; when missing, execute is never called and no data is read. */
  permission?: PermissionType;
  /** Side-effect tools write their own audit record (AWAITING_CONFIRMATION). */
  selfAudited?: boolean;
  /** The category the app shows for this tool (never the tool's own name). */
  kind: ToolEventKind;
  /**
   * What the app may show for a successful result. Defaults to just "success" with no data;
   * only the user's own data, already filtered by the tool, may go here.
   */
  display?(data: unknown): { status?: ToolEventStatus; data?: Record<string, unknown> };
  execute(input: INPUT, ctx: ToolContext): Promise<ToolResult<unknown>>;
}

/** Wraps a tool so permission checks, error handling and the audit trail are never skipped. */
export function defineChatTool<INPUT>(ctx: ToolContext, spec: ChatToolSpec<INPUT>): Tool {
  return tool({
    description: spec.description,
    inputSchema: spec.inputSchema,
    execute: async (input: INPUT): Promise<ToolResult<unknown>> => {
      ctx.run.toolsUsed.push(spec.name);

      let result: ToolResult<unknown>;
      if (spec.permission && !(await hasPermission(ctx.userId, spec.permission))) {
        result = permissionRequired(spec.permission);
      } else {
        try {
          result = await spec.execute(input, ctx);
        } catch (err) {
          // The model gets a generic failure; details stay in the server log only.
          const e = err instanceof Error ? err : new Error(String(err));
          console.error(`Chat tool ${spec.name} failed: ${e.name}: ${e.message}`);
          result = fail("TOOL_FAILED", "This tool could not complete. Nothing was changed.");
        }
      }

      if (!spec.selfAudited || !result.success) {
        await audit(ctx, spec.name, statusFor(result));
      }
      ctx.run.events.push(eventFor(spec, result));
      return result;
    },
  }) as Tool;
}

function eventFor<INPUT>(spec: ChatToolSpec<INPUT>, result: ToolResult<unknown>): ToolEvent {
  if (result.success) {
    const shown = spec.display?.(result.data) ?? {};
    return { kind: spec.kind, status: shown.status ?? "success", ...(shown.data ? { data: shown.data } : {}) };
  }
  const status: ToolEventStatus = (() => {
    switch (result.code) {
      case "PERMISSION_REQUIRED":
        return "permission_required";
      case "WEB_SEARCH_NOT_CONFIGURED":
      case "CONTACTS_NOT_CONFIGURED":
      case "ACTION_NOT_CONFIGURED":
        return "not_configured";
      case "INVALID_ARGUMENTS":
        return "invalid";
      case "TOOL_FAILED":
        return "failed";
      default:
        return "unavailable";
    }
  })();
  return { kind: spec.kind, status, ...(result.permission ? { permission: result.permission } : {}) };
}

function statusFor(result: ToolResult<unknown>): ToolCallStatus {
  if (result.success) return "SUCCEEDED";
  return result.code === "PERMISSION_REQUIRED" ? "BLOCKED" : "FAILED";
}

// Audit records hold only the tool name and outcome: never arguments or results.
async function audit(ctx: ToolContext, toolName: string, status: ToolCallStatus): Promise<void> {
  try {
    await recordToolCall(ctx.userId, ctx.conversationId, { toolName, status });
  } catch (err) {
    const e = err instanceof Error ? err : new Error(String(err));
    console.error(`Could not audit chat tool ${toolName}: ${e.name}: ${e.message}`);
  }
}
